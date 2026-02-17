# frozen_string_literal: true

require "yaml"
require "logger"
require "thread"

module WebTechFeeder
  # Loads and provides access to application configuration
  class Config
    SOURCES_PATH = File.expand_path("sources.yml", __dir__)
    TPE_UTC_OFFSET = "+08:00"

    attr_reader :sources, :logger
    attr_accessor :run_id

    def initialize
      @sources = YAML.safe_load_file(SOURCES_PATH, symbolize_names: true)
      @logger = build_logger
      @runtime_cache = {}
      @runtime_cache_mutex = Mutex.new
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

    def email_bcc
      ENV["EMAIL_BCC"]
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

    # Use Taiwan (TPE, UTC+8) as the date boundary for full-day lookback.
    # Example: if now is 2026-02-17 xx:xx in TPE and lookback_days=7,
    # cutoff is 2026-02-10 00:00:00 +08:00.
    def cutoff_time
      now_tpe = Time.now.getlocal(TPE_UTC_OFFSET)
      midnight_tpe = Time.new(now_tpe.year, now_tpe.month, now_tpe.day, 0, 0, 0, TPE_UTC_OFFSET)
      midnight_tpe - (lookback_days * 24 * 60 * 60)
    end

    # Minimum importance: "critical" | "high" | "medium" | "low" (default: "high")
    def digest_min_importance
      ENV.fetch("DIGEST_MIN_IMPORTANCE", "high")
    end

    # Toggle deep PR crawling (PR compare + linked PR resolution).
    # Set false to speed up experiments.
    def deep_pr_crawl?
      ENV.fetch("DEEP_PR_CRAWL", "true").downcase == "true"
    end

    # Section-aware file path filters used by compare blocks.
    # Returns an array of regex pattern strings for :frontend/:backend/:devops.
    def section_file_filter_patterns(section_key)
      return [] if section_key.nil?

      filters = @sources[:section_file_filters] || {}
      patterns = filters[section_key.to_sym]
      patterns.is_a?(Array) ? patterns : []
    end

    # Run-level in-memory cache to avoid duplicated API calls.
    # Caches nil values as well (e.g., 404) to suppress repeated retries.
    def cache_fetch(namespace, key)
      ns_key = namespace.to_s
      entry_key = key.to_s

      @runtime_cache_mutex.synchronize do
        namespace_cache = (@runtime_cache[ns_key] ||= {})
        if namespace_cache.key?(entry_key)
          value = namespace_cache[entry_key]
          logger.info("#{cid_tag}[cache-hit] #{ns_key} key=#{entry_key} value=#{cache_value_summary(value)}")
          return value
        end
      end

      value = yield

      @runtime_cache_mutex.synchronize do
        (@runtime_cache[ns_key] ||= {})[entry_key] = value
      end
      value
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

    def cid_tag
      rid = run_id.to_s.strip
      rid.empty? ? "" : "[cid=#{rid}] "
    end

    def cache_value_summary(value)
      case value
      when nil
        "nil"
      when Array
        "Array(size=#{value.size})"
      when Hash
        keys = value.keys.first(3).map(&:to_s).join(",")
        value.size > 3 ? "Hash(keys=#{keys},...)" : "Hash(keys=#{keys})"
      else
        value.class.to_s
      end
    end
  end
end
