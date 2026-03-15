# frozen_string_literal: true

require "faraday"
require "json"
require_relative "base_processor"

module WebTechFeeder
  module Processor
    # OpenAI-compatible API provider.
    # Works with: OpenRouter, Groq, Together AI, local Ollama, OpenAI, etc.
    # All providers use the /chat/completions endpoint.
    #
    # Configuration via environment variables:
    #   AI_API_URL   - Base URL (e.g. "https://openrouter.ai/api/v1")
    #   AI_API_KEY   - API key (optional for some providers like Ollama)
    #   AI_MODEL     - Model name (e.g. "gpt-4.1-mini")
    # Non-retryable API error (e.g. 401/403/404).
    # Raised to bypass category-level retry in BaseProcessor.
    class FatalApiError < RuntimeError; end

    class OpenaiProcessor < BaseProcessor
      RETRYABLE_HTTP_STATUSES = [429, 500, 502, 503, 504].freeze
      FATAL_HTTP_STATUSES = [401, 403, 404].freeze
      MAX_HTTP_STATUS_RETRIES = 2

      def provider_name
        "OpenAI-compatible (#{config.ai_model} @ #{config.ai_api_url})"
      end

      def call_api(prompt)
        conn = build_connection

        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{config.ai_api_key}" if config.ai_api_key && !config.ai_api_key.empty?
        headers["HTTP-Referer"] = "https://github.com/web-tech-feeder" if config.ai_api_url.include?("openrouter")
        headers["X-Title"] = "Web Tech Feeder" if config.ai_api_url.include?("openrouter")

        endpoint = build_chat_endpoint
        body = build_chat_request_body(prompt)
        response = post_with_status_retry(conn, endpoint, body, headers)

        unless response.status == 200
          message = extract_error_message(response.body)
          detail = message.empty? ? response.body.to_s[0..500] : message
          error_class = FATAL_HTTP_STATUSES.include?(response.status) ? FatalApiError : RuntimeError
          raise error_class, "API returned status #{response.status}: #{detail}"
        end

        parsed = JSON.parse(response.body)

        raise "API error: #{parsed['error']['message'] || parsed['error']}" if parsed["error"]

        choice = parsed.dig("choices", 0)
        text = choice&.dig("message", "content")

        if text.nil? || text.strip.empty?
          finish_reason = choice&.dig("finish_reason")
          usage = parsed["usage"]
          logger.warn("Empty API response. finish_reason=#{finish_reason.inspect}, usage=#{usage.inspect}")
          logger.warn("Full response (truncated): #{parsed.to_json[0..800]}...")
          raise "Empty response from API (finish_reason=#{finish_reason})"
        end

        text
      end

      private

      def system_prompt
        "You are a senior software engineering newsletter editor. " \
          "Output ONLY valid JSON. No introduction, no explanation, no text before or after. Start with { and end with }. " \
          "MUST include 1-2 items from GitHub Issues/PRs or RSS/Blog when available - never omit PR/Issue/Blog entirely. " \
          "Summaries: 📌 核心重點 + 🔍 技術細節 + 📊 建議動作. " \
          "item_type: 'release'|'advisory'|'issue'|'other'. " \
          "LANGUAGE: Traditional Chinese only. TECHNICAL TERMS: Keep in English. " \
          "Output up to 7 items per category (releases + others combined), balanced across releases, advisories, and Issue/PR/Blog."
      end

      # Some models (GPT-5.x, o1, o3) require max_completion_tokens instead of max_tokens.
      # Set AI_USE_MAX_COMPLETION_TOKENS=true to force max_completion_tokens for any model.
      def uses_max_completion_tokens?
        return true if ENV["AI_USE_MAX_COMPLETION_TOKENS"]&.downcase == "true"

        model = config.ai_model.to_s.downcase
        model.match?(/gpt-5|o1-|o3-/)
      end

      def build_chat_request_body(prompt)
        base = {
          model: config.ai_model,
          messages: [
            {
              role: "system",
              content: system_prompt
            },
            { role: "user", content: prompt }
          ],
          temperature: 0.2
        }
        token_key = uses_max_completion_tokens? ? :max_completion_tokens : :max_tokens
        base[token_key] = config.ai_max_tokens
        base
      end

      def build_chat_endpoint
        base = config.ai_api_url.chomp("/")
        "#{base}/chat/completions"
      end

      def post_with_status_retry(conn, endpoint, body, headers)
        attempt = 0
        loop do
          logger.debug("POST #{endpoint}")
          response = conn.post(endpoint, body.to_json, headers)
          return response if response.status == 200
          return response if FATAL_HTTP_STATUSES.include?(response.status)
          return response unless RETRYABLE_HTTP_STATUSES.include?(response.status)
          return response if attempt >= MAX_HTTP_STATUS_RETRIES

          wait = 2 * (2**attempt)
          message = extract_error_message(response.body)
          logger.warn("Transient API status #{response.status} from #{endpoint}; retry in #{wait}s (attempt #{attempt + 1}/#{MAX_HTTP_STATUS_RETRIES}). message=#{message[0..200]}")
          sleep(wait)
          attempt += 1
        rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
          raise if attempt >= MAX_HTTP_STATUS_RETRIES

          wait = 2 * (2**attempt)
          logger.warn("Transient network error from #{endpoint}; retry in #{wait}s (attempt #{attempt + 1}/#{MAX_HTTP_STATUS_RETRIES}). error=#{e.class}: #{e.message}")
          sleep(wait)
          attempt += 1
        end
      end

      def extract_error_message(body)
        parsed = JSON.parse(body.to_s)
        parsed.dig("error", "message").to_s
      rescue JSON::ParserError
        ""
      end

      def build_connection
        Faraday.new do |f|
          f.request :retry, max: 2, interval: 2, backoff_factor: 2,
                            exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
          f.adapter Faraday.default_adapter
          f.options.timeout = 120
          f.options.open_timeout = 30
        end
      end
    end
  end
end
