# frozen_string_literal: true

require "yaml"
require "logger"

module WebTechFeeder
  # Loads and provides access to application configuration
  class Config
    SOURCES_PATH = File.expand_path("sources.yml", __dir__)

    attr_reader :sources, :logger

    def initialize
      @sources = YAML.safe_load_file(SOURCES_PATH, symbolize_names: true)
      @logger = build_logger
    end

    def github_token
      ENV.fetch("GITHUB_TOKEN", nil)
    end

    # --- AI Provider Settings ---

    # Which AI provider to use: "gemini" or "openai"
    # "openai" is compatible with OpenRouter, Groq, Together AI, Ollama, etc.
    def ai_provider
      ENV.fetch("AI_PROVIDER", "gemini")
    end

    # Gemini-specific settings
    def gemini_api_key
      ENV.fetch("GEMINI_API_KEY", nil)
    end

    def gemini_model
      ENV.fetch("GEMINI_MODEL", "gemini-2.0-flash-lite")
    end

    # OpenAI-compatible API settings (works with OpenRouter, Groq, Ollama, etc.)
    def ai_api_url
      ENV.fetch("AI_API_URL", "https://openrouter.ai/api/v1")
    end

    def ai_api_key
      ENV.fetch("AI_API_KEY", nil)
    end

    def ai_model
      ENV.fetch("AI_MODEL", "openrouter/free")
    end

    # Max tokens for completion. Reasoning models (e.g. nvidia/nemotron) use tokens for
    # internal reasoning + output; 8192 often leaves no room for content. Use 16384+
    def ai_max_tokens
      ENV.fetch("AI_MAX_TOKENS", "16384").to_i
    end

    # --- Gmail OAuth Settings ---
    # Uses OAuth 2.0 refresh token instead of password.
    # Obtain token via Google OAuth 2.0 Playground or one-time OAuth flow.

    def gmail_client_id
      ENV.fetch("GMAIL_CLIENT_ID")
    end

    def gmail_client_secret
      ENV.fetch("GMAIL_CLIENT_SECRET")
    end

    def gmail_refresh_token
      ENV.fetch("GMAIL_REFRESH_TOKEN")
    end

    def email_from
      ENV.fetch("EMAIL_FROM")
    end

    def email_to
      ENV.fetch("EMAIL_TO")
    end

    # Dry-run mode: collect + process but skip email sending,
    # and save the HTML output to tmp/digest_preview.html instead
    def dry_run?
      ENV.fetch("DRY_RUN", "false").downcase == "true"
    end

    # Number of days to look back for new content
    def lookback_days
      ENV.fetch("LOOKBACK_DAYS", "7").to_i
    end

    def cutoff_time
      Time.now - (lookback_days * 24 * 60 * 60)
    end

    # Minimum importance: "critical" | "high" | "medium" | "low" (default: "high")
    def digest_min_importance
      ENV.fetch("DIGEST_MIN_IMPORTANCE", "high")
    end

    private

    def build_logger
      logger = Logger.new($stdout)
      logger.level = ENV.fetch("LOG_LEVEL", "INFO")
      logger.formatter = proc do |severity, datetime, _progname, msg|
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
      end
      logger
    end
  end
end
