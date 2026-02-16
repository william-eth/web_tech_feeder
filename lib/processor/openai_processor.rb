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
      def provider_name
        "OpenAI-compatible (#{config.ai_model} @ #{config.ai_api_url})"
      end

      # Sends prompt via OpenAI Chat Completions API and returns response text
      def call_api(prompt)
        conn = build_connection
        endpoint = build_endpoint

        body = {
          model: config.ai_model,
          messages: [
            {
              role: "system",
              content: "You are a senior software engineering newsletter editor. " \
                       "Output ONLY valid JSON. No introduction, no explanation, no text before or after. Start with { and end with }. " \
                       "MUST include 1-2 items from GitHub Issues/PRs or RSS/Blog when available - never omit PR/Issue/Blog entirely. " \
                       "Summaries: 📌 核心重點 + 🔍 技術細節 + 📊 建議動作. " \
                       "item_type: 'release'|'advisory'|'issue'|'other'. " \
                       "LANGUAGE: Traditional Chinese only. TECHNICAL TERMS: Keep in English. " \
                       "Output up to 7 items per category (releases + others combined), balanced across releases, advisories, and Issue/PR/Blog."
            },
            { role: "user", content: prompt }
          ],
          temperature: 0.2,
          max_tokens: config.ai_max_tokens
        }

        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{config.ai_api_key}" if config.ai_api_key && !config.ai_api_key.empty?
        headers["HTTP-Referer"] = "https://github.com/web-tech-feeder" if config.ai_api_url.include?("openrouter")
        headers["X-Title"] = "Web Tech Feeder" if config.ai_api_url.include?("openrouter")

        logger.debug("POST #{endpoint}")
        response = conn.post(endpoint, body.to_json, headers)

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
        text = choice&.dig("message", "content")

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

      def build_endpoint
        # Ensure correct URL construction regardless of trailing slash in base URL
        base = config.ai_api_url.chomp("/")
        "#{base}/chat/completions"
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
