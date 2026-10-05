# frozen_string_literal: true

module PdfManifests
  # = PdfManifests::OllamaClient
  #
  #   - version:  7-0.10.55
  #   - author:   Devin
  #
  # Thin wrapper around a locally-running Ollama server API.
  # Used by the manifest extraction pipeline to pull structured JSON data
  # out of meeting manifest text (or rendered page images for scanned PDFs).
  #
  # Configuration (ENV):
  # - OLLAMA_API_URL        => base API URL (default: http://localhost:11434)
  # - OLLAMA_MANIFEST_MODEL => model used for text extraction (default: gemma4:e4b)
  # - OLLAMA_VISION_MODEL   => model used for image extraction (default: same as manifest model)
  #
  class OllamaClient
    class Error < StandardError; end

    # Default generation options tuned for structured extraction:
    # - 'think' must be disabled or "thinking" models may burn the whole
    #   output budget on reasoning and truncate the JSON response.
    # - 'num_ctx' must exceed prompt_tokens + expected output: Ollama's
    #   default context (4096) silently truncates long manifest prompts.
    GENERATE_OPTIONS = {
      temperature: 0.1,
      num_predict: 8192,
      num_ctx: 16_384
    }.freeze

    GENERATE_TIMEOUT_SECS = 300
    PING_TIMEOUT_SECS = 3

    attr_reader :base_url, :model, :vision_model

    def initialize(base_url: nil, model: nil, vision_model: nil)
      @base_url = base_url || ENV.fetch('OLLAMA_API_URL', 'http://localhost:11434')
      @model = model || ENV.fetch('OLLAMA_MANIFEST_MODEL', 'gemma4:e4b')
      @vision_model = vision_model || ENV.fetch('OLLAMA_VISION_MODEL', @model)
    end

    # TRUE when the ollama binary is installed AND the API endpoint responds.
    def available?
      self.class.installed? && models.present?
    end

    # TRUE when an 'ollama' executable is found on PATH.
    def self.installed?
      system('which ollama > /dev/null 2>&1')
    end

    # Cached list of models reported by the local server (as name => details Hash).
    # Returns an empty Hash when the server is unreachable.
    def models
      @models ||= begin
        res = RestClient::Request.execute(
          method: :get, url: "#{@base_url}/api/tags",
          open_timeout: PING_TIMEOUT_SECS, read_timeout: PING_TIMEOUT_SECS
        )
        Array(JSON.parse(res.body)['models']).index_by { |m| m['name'] }
      rescue StandardError
        {}
      end
    end

    # TRUE when the given model is installed and supports the specified capability
    # (e.g. 'completion', 'vision'). Matches on the exact tag first, then on the
    # family name so 'gemma4' also matches an installed 'gemma4:e4b' tag.
    def model_supports?(model_name, capability)
      entry = models[model_name] || models.find { |name, _| name.to_s.start_with?("#{model_name}:") }&.last
      capabilities = entry.is_a?(Hash) ? Array(entry['capabilities']) : []
      capabilities.map(&:to_s).include?(capability.to_s)
    end

    # TRUE when the configured vision model is usable for image extraction.
    def vision_available?
      available? && model_supports?(@vision_model, 'vision')
    end

    # Sends a generation request. Returns the parsed JSON response body (as Hash)
    # or raises Error.
    #
    # == Params
    # - prompt: text prompt
    # - images: optional Array of base64-encoded images (vision models)
    # - model: override for the configured model name
    #
    def generate(prompt:, images: nil, model: nil)
      use_model = model || (images.present? ? @vision_model : @model)
      body = {
        model: use_model,
        prompt: prompt,
        stream: false,
        think: false,
        format: 'json',
        options: GENERATE_OPTIONS
      }
      body[:images] = images if images.present?

      2.times do |attempt|
        response = execute_generate(body)
        raw = response['response'].to_s
        begin
          return JSON.parse(raw)
        rescue JSON::ParserError
          raise Error, "Ollama (#{use_model}) returned invalid JSON after retry" if attempt.positive?
        end
      end
    end

    private

    def execute_generate(body)
      res = RestClient::Request.execute(
        method: :post, url: "#{@base_url}/api/generate",
        payload: body.to_json, content_type: :json,
        open_timeout: PING_TIMEOUT_SECS, read_timeout: GENERATE_TIMEOUT_SECS
      )
      JSON.parse(res.body)
    rescue RestClient::ExceptionWithResponse, SocketError, Errno::ECONNREFUSED => e
      raise Error, "Ollama API request failed: #{e.message}"
    end
  end
end
