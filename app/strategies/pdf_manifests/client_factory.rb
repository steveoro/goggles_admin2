# frozen_string_literal: true

module PdfManifests
  # = PdfManifests::ClientFactory
  #
  #   - version:  7-0.10.66
  #   - author:   Devin
  #
  # Resolves the LLM client used by the manifest extraction pipeline:
  # 'devin' (default) shells out to `devin -p` non-interactive sessions via
  # DevinClient; 'ollama' uses the local Ollama server via OllamaClient.
  # Selection order: explicit engine param > MANIFEST_ENGINE env > default.
  #
  module ClientFactory
    ENGINES = %w[devin ollama].freeze
    DEFAULT_ENGINE = 'devin'

    # Engine used when no explicit choice is given ('devin' unless overridden).
    def self.default_engine
      ENV.fetch('MANIFEST_ENGINE', DEFAULT_ENGINE)
    end

    # Builds the client for the given engine id (nil => default engine).
    # Raises ArgumentError on an unknown engine name.
    def self.build(engine: nil, model: nil)
      case (engine.presence || default_engine).to_s
      when 'devin' then DevinClient.new(model: model)
      when 'ollama' then OllamaClient.new(model: model)
      else
        raise ArgumentError, "unknown extraction engine '#{engine}' (valid: #{ENGINES.join(', ')})"
      end
    end
  end
end
