# frozen_string_literal: true

require 'base64'
require 'open3'
require 'tmpdir'

module PdfManifests
  # = PdfManifests::DevinClient
  #
  #   - version:  7-0.10.66
  #   - author:   Devin
  #
  # Drop-in alternative to OllamaClient for the manifest extraction pipeline:
  # each #generate spawns a fresh `devin -p` single-turn, non-interactive
  # session and parses the JSON printed on stdout.
  #
  # Implementation notes:
  # - The run happens inside a dedicated temp dir used as the CLI working
  #   directory: the prompt is passed via --prompt-file and page images for
  #   scanned PDFs are written there as PNGs the agent can open with its
  #   file-reading tool (read-only tools auto-approve within the working dir
  #   under the default 'auto' permission mode).
  # - '--respect-workspace-trust false' is required: non-interactive mode
  #   cannot answer the workspace-trust prompt and would fail outright.
  # - Agent/IDE context variables (ACP_BACKEND & friends, injected when the
  #   caller itself runs inside an agent session) make a nested `devin`
  #   report "Not logged in" even with valid credentials - SCRUBBED_ENV_KEYS
  #   are explicitly unset from the spawned process environment.
  #
  # Configuration (ENV):
  # - DEVIN_MANIFEST_MODEL => model used for extraction (default: swe-2-high)
  # - DEVIN_VISION_MODEL   => model used for page-image extraction (default: same)
  #
  class DevinClient
    class Error < StandardError; end

    DEFAULT_MODEL = 'swe-2-high'
    GENERATE_TIMEOUT_SECS = 900
    KILL_GRACE_SECS = 15
    MODELS_TIMEOUT_SECS = 15

    # Agent/IDE context variables that must not leak into the spawned `devin`
    # process (they make the CLI believe it is nested inside another agent
    # session and refuse the user credentials - ACP_BACKEND is the proven one).
    SCRUBBED_ENV_KEYS = %w[
      ACP_BACKEND ACP_AGENT AI_AGENT
      ELECTRON_RUN_AS_NODE
      WINDSURF_IDE_TYPE WINDSURF_EXT_HOST_PID WINDSURF_CODEIUM_DIR
      VSCODE_PID VSCODE_IPC_HOOK VSCODE_CWD VSCODE_ESM_ENTRYPOINT
      VSCODE_HANDLES_UNCAUGHT_ERRORS VSCODE_NLS_CONFIG VSCODE_CODE_CACHE_PATH
      GIT_TERMINAL_PROMPT
    ].freeze

    # Appended to every prompt: the CLI runs an agent, so the output contract
    # must be restated in agent terms.
    AGENT_RULES = <<~TEXT

      IMPORTANT - this is a non-interactive batch extraction, not an interactive session:
      - your entire reply must be the raw JSON object only: no markdown fences, no commentary
      - do not create, modify or delete any file; do not use any tool
    TEXT

    AGENT_IMAGE_RULES = <<~TEXT

      IMPORTANT - this is a non-interactive batch extraction, not an interactive session:
      - the manifest is provided as page images saved in the current directory (%<files>s):
        read each image file with your file-reading tool, then answer
      - your entire reply must be the raw JSON object only: no markdown fences, no commentary
      - do not create, modify or delete any file
    TEXT

    attr_reader :model, :vision_model

    def initialize(model: nil, vision_model: nil)
      @model = model || ENV.fetch('DEVIN_MANIFEST_MODEL', DEFAULT_MODEL)
      @vision_model = vision_model || ENV.fetch('DEVIN_VISION_MODEL', @model)
    end

    # Human-readable engine label used by callers for preflight/status lines.
    def engine_name = 'Devin CLI'

    # TRUE when the devin binary is on PATH AND the CLI can authenticate
    # (a `devin models list` round-trip: fails fast when not logged in).
    def available? = self.class.installed? && models_fetched?

    # TRUE when a 'devin' executable is found on PATH.
    def self.installed? = system('which devin > /dev/null 2>&1')

    # Set of usable model ids (variants' model_uid plus family slugs/aliases,
    # so short names like 'swe'/'swe-2' also resolve). Empty Hash when the
    # CLI call failed (auth/transport) - check #models_fetched? to distinguish.
    def models
      return @models if defined?(@models)

      @models_fetched = false
      @models = begin
        out, _err, status = Open3.capture3(
          scrubbed_env, 'timeout', '-k', '5', MODELS_TIMEOUT_SECS.to_s,
          'devin', 'models', 'list', '--format', 'json'
        )
        @models_fetched = status.success?
        @models_fetched ? extract_model_ids(out) : {}
      rescue StandardError
        {}
      end
    end

    # TRUE when the last `devin models list` call succeeded (CLI authenticated).
    def models_fetched? = models && @models_fetched

    # TRUE when the configured model is listed for the account. When the list
    # was fetched but came back empty/unparseable we don't block preflight on
    # something we can't verify - a bad model surfaces at generate time.
    def model_available?(model_name = @model) = models.empty? || models.key?(model_name.to_s)

    # TRUE when page-image extraction can run: the agent reads the rendered
    # PNG files itself, so any working model counts as vision-capable.
    def vision_available? = available?

    # Hint shown by callers when #available? is false.
    def unavailable_hint = 'check `devin auth status`; run `devin auth login` if needed'

    # Hint shown by callers when #model_available? is false.
    def model_missing_hint = 'check available ids with `devin models list`'

    # Sends a prompt to a fresh `devin -p` session. Returns the parsed JSON
    # object (as Hash) or raises Error. Like OllamaClient#generate, one retry
    # is attempted only when the reply is not valid JSON.
    #
    # == Params
    # - prompt: text prompt
    # - images: optional Array of base64-encoded images (written as PNG files
    #   the agent reads from its working dir)
    # - model: override for the configured model name
    #
    def generate(prompt:, images: nil, model: nil)
      use_model = model || (images.present? ? @vision_model : @model)

      2.times do |attempt|
        parsed = parse_json_output(run_devin(prompt, images, use_model))
        return parsed if parsed

        raise Error, "devin (#{use_model}) returned invalid JSON after retry" if attempt.positive?
      end
    end

    private

    # Environment passed to spawned `devin` processes: every agent/IDE context
    # key explicitly unset so the CLI uses the real user credentials.
    def scrubbed_env
      @scrubbed_env ||= SCRUBBED_ENV_KEYS.index_with(nil)
    end

    # Runs a single `devin -p` session inside a temp working dir holding the
    # prompt file (and the decoded page images, when present).
    # Returns the raw stdout. Raises Error on timeout/failure.
    def run_devin(prompt, images, use_model)
      Dir.mktmpdir('devin_manifest') do |dir|
        prompt_file = File.join(dir, 'prompt.txt')
        File.write(prompt_file, "#{prompt}\n#{agent_rules(images, dir)}")

        stdout, stderr, status = Open3.capture3(
          scrubbed_env, 'timeout', '-k', KILL_GRACE_SECS.to_s, GENERATE_TIMEOUT_SECS.to_s,
          'devin', '--model', use_model, '--verbosity', '0',
          '--respect-workspace-trust', 'false', '-p', '--prompt-file', prompt_file,
          chdir: dir
        )
        raise Error, "devin CLI timed out after #{GENERATE_TIMEOUT_SECS}s (#{use_model})" if [124, 137].include?(status.exitstatus)

        unless status.success?
          detail = stderr.to_s.strip.presence || stdout.to_s.strip
          raise Error, "devin CLI failed (exit #{status.exitstatus}): #{detail.last(300)}"
        end

        stdout
      end
    end

    # The no-tools / JSON-only contract appended to every prompt; for image
    # payloads also names the PNG files written into the working dir.
    def agent_rules(images, dir)
      return AGENT_RULES if images.blank?

      files = write_images(images, dir).map { |f| File.basename(f) }
      format(AGENT_IMAGE_RULES, files: files.join(', '))
    end

    # Decodes base64 page images into 'page-N.png' files inside dir.
    def write_images(images, dir)
      Array(images).each_with_index.map do |b64, idx|
        path = File.join(dir, "page-#{idx + 1}.png")
        File.binwrite(path, Base64.decode64(b64.to_s))
        path
      end
    end

    # Extracts the JSON object from the CLI stdout. Accepts a bare JSON reply,
    # a markdown-fenced block, or JSON embedded in surrounding prose (first
    # '{' .. last '}'). Returns the Hash or nil when nothing parses.
    def parse_json_output(raw)
      text = raw.to_s.gsub(/\e\[[0-9;]*[A-Za-z]/, '').strip
      [text, text[/```(?:json)?\s*(\{.*?\})\s*```/m, 1], text[/\{.*\}/m]].compact.each do |candidate|
        parsed = begin
          JSON.parse(candidate)
        rescue JSON::ParserError
          nil
        end
        return parsed if parsed.is_a?(Hash)
      end
      nil
    end

    # Parses `devin models list --format json` into a {id => true} lookup of
    # every model_uid plus family slug/uid/aliases.
    def extract_model_ids(raw)
      ids = []
      Array(JSON.parse(raw.to_s)['families']).each do |fam|
        ids.push(fam['slug'], fam['family_uid'], *Array(fam['aliases']))
        Array(fam['variants']).each { |v| ids << v['model_uid'] }
      end
      ids.compact.map(&:to_s).index_with(true)
    rescue JSON::ParserError
      {}
    end
  end
end
