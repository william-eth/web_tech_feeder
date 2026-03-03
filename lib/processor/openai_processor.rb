# frozen_string_literal: true

require "faraday"
require "json"
require_relative "base_processor"

module WebTechFeeder
  module Processor
    # OpenAI-compatible API provider.
    # Works with: OpenRouter, Groq, Together AI, local Ollama, OpenAI, etc.
    #
    # Configuration via environment variables:
    #   AI_API_URL   - Base URL (e.g. "https://openrouter.ai/api/v1")
    #   AI_API_KEY   - API key (optional for some providers like Ollama)
    #   AI_MODEL     - Model name (e.g. "openrouter/free")
    class OpenaiProcessor < BaseProcessor
      RETRYABLE_HTTP_STATUSES = [429, 500, 502, 503, 504].freeze
      MAX_HTTP_STATUS_RETRIES = 2

      def provider_name
        "OpenAI-compatible (#{config.ai_model} @ #{config.ai_api_url})"
      end

      # Sends prompt via OpenAI-compatible API and returns response text.
      # Primary path: /chat/completions. If model is completion-only,
      # fallback to /completions automatically.
      def call_api(prompt)
        conn = build_connection
        mode = :chat

        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{config.ai_api_key}" if config.ai_api_key && !config.ai_api_key.empty?
        headers["HTTP-Referer"] = "https://github.com/web-tech-feeder" if config.ai_api_url.include?("openrouter")
        headers["X-Title"] = "Web Tech Feeder" if config.ai_api_url.include?("openrouter")

        response = post_chat_completion(conn, prompt, headers)
        if chat_endpoint_not_supported?(response)
          logger.warn("Model #{config.ai_model} is not chat-compatible on this provider; fallback to /completions")
          response = post_text_completion(conn, prompt, headers)
          mode = :completion
        end

        # Manual status check with detailed error reporting
        unless response.status == 200
          error_body = response.body.to_s[0..500]
          raise "API returned status #{response.status}: #{error_body}"
        end

        parsed = JSON.parse(response.body)

        if parsed["error"]
          raise "API error: #{parsed['error']['message'] || parsed['error']}"
        end

        choice = parsed.dig("choices", 0)
        text = extract_response_text(choice, mode)

        if text.nil? || text.strip.empty?
          # Debug: log raw response structure to diagnose empty content
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

      def build_completion_request_body(prompt)
        {
          model: config.ai_model,
          prompt: "#{system_prompt}\n\nUSER TASK:\n#{prompt}\n\nReturn ONLY valid JSON.",
          temperature: 0.2,
          max_tokens: [config.ai_max_tokens, 8192].min
        }
      end

      def build_chat_endpoint
        # Ensure correct URL construction regardless of trailing slash in base URL
        base = config.ai_api_url.chomp("/")
        "#{base}/chat/completions"
      end

      def build_completion_endpoint
        base = config.ai_api_url.chomp("/")
        "#{base}/completions"
      end

      def post_chat_completion(conn, prompt, headers)
        endpoint = build_chat_endpoint
        body = build_chat_request_body(prompt)
        post_with_status_retry(conn, endpoint, body, headers)
      end

      def post_text_completion(conn, prompt, headers)
        endpoint = build_completion_endpoint
        body = build_completion_request_body(prompt)
        post_with_status_retry(conn, endpoint, body, headers)
      end

      def post_with_status_retry(conn, endpoint, body, headers)
        attempt = 0
        loop do
          logger.debug("POST #{endpoint}")
          response = conn.post(endpoint, body.to_json, headers)
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

      def chat_endpoint_not_supported?(response)
        return false unless [400, 404].include?(response.status)

        message = extract_error_message(response.body)
        return false if message.empty?

        lowered = message.downcase
        lowered.include?("not a chat model") ||
          lowered.include?("not supported in the v1/chat/completions endpoint") ||
          lowered.include?("did you mean to use v1/completions")
      end

      def extract_error_message(body)
        parsed = JSON.parse(body.to_s)
        parsed.dig("error", "message").to_s
      rescue JSON::ParserError
        ""
      end

      def extract_response_text(choice, mode)
        if mode == :completion
          return choice&.dig("text")
        end

        choice&.dig("message", "content")
      end

      def build_connection
        # Do NOT use raise_error middleware - we handle errors manually for better logging
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
