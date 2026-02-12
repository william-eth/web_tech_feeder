# frozen_string_literal: true

require "faraday"
require "json"
require_relative "base_processor"

module WebTechFeeder
  module Processor
    # Gemini API provider (Google AI Studio).
    # Uses the REST API directly via Faraday.
    class GeminiProcessor < BaseProcessor
      GEMINI_API_URL = "https://generativelanguage.googleapis.com"

      def provider_name
        "Gemini (#{config.gemini_model})"
      end

      # Sends prompt to Gemini and returns the response text
      def call_api(prompt)
        conn = build_connection
        model = config.gemini_model

        body = {
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: {
            temperature: 0.2,
            maxOutputTokens: config.ai_max_tokens,
            responseMimeType: "application/json"
          }
        }

        response = conn.post(
          "/v1beta/models/#{model}:generateContent?key=#{config.gemini_api_key}",
          body.to_json,
          "Content-Type" => "application/json"
        )

        parsed = JSON.parse(response.body)
        parsed.dig("candidates", 0, "content", "parts", 0, "text")
      end

      private

      def build_connection
        Faraday.new(url: GEMINI_API_URL) do |f|
          f.request :retry, max: 2, interval: 2, backoff_factor: 2,
                            exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
          f.response :raise_error
          f.adapter Faraday.default_adapter
          f.options.timeout = 120
          f.options.open_timeout = 30
        end
      end
    end
  end
end
