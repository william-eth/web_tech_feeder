# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"

module WebTechFeeder
  module Collectors
    # Abstract base class for all data collectors.
    # Provides shared Faraday HTTP client, error handling, and retry logic.
    class BaseCollector
      Item = Struct.new(:title, :url, :published_at, :body, :source, keyword_init: true)

      attr_reader :config, :logger

      def initialize(config)
        @config = config
        @logger = config.logger
      end

      # Subclasses must implement this method.
      # Returns an Array of Item structs.
      def collect
        raise NotImplementedError, "#{self.class}#collect must be implemented"
      end

      private

      # Build a Faraday connection with retry middleware (includes SSL/EOF transient errors)
      def build_connection(base_url, headers: {})
        retry_exceptions = [
          Faraday::TimeoutError,
          Faraday::ConnectionFailed,
          Faraday::SSLError,
          OpenSSL::SSL::SSLError,
          Errno::ECONNRESET,
          Errno::EPIPE,
          EOFError
        ]

        Faraday.new(url: base_url, headers: default_headers.merge(headers)) do |f|
          f.request :retry, max: 3, interval: 2, backoff_factor: 2,
                            exceptions: retry_exceptions
          f.response :raise_error
          f.adapter Faraday.default_adapter
        end
      end

      def default_headers
        {
          "Accept" => "application/json",
          "User-Agent" => "WebTechFeeder/1.0"
        }
      end

      # Filter items published after the cutoff time
      def recent?(published_at)
        return false if published_at.nil?

        published_at >= config.cutoff_time
      end

      # Safely parse a time string, returning nil on failure
      def safe_parse_time(time_string)
        Time.parse(time_string.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      # Truncate body text to a reasonable size for AI processing
      def truncate_body(text, max_length: 1000)
        return "" if text.nil? || text.empty?

        text.length > max_length ? "#{text[0...max_length]}..." : text
      end

      def cid_tag
        rid = config.respond_to?(:run_id) ? config.run_id.to_s : ""
        rid.empty? ? "" : "cid=#{rid} "
      end
    end
  end
end
