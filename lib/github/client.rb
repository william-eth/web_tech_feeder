# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"
require_relative "../utils/log_context"
require_relative "../utils/log_tag_styler"

module WebTechFeeder
  module Github
    # Shared GitHub API client for collectors/enrichers.
    # Handles auth headers, caching, and common paginated fetch flows.
    class Client
      API_URL = "https://api.github.com"
      RATE_LIMIT_MAX_RETRIES = 4
      RATE_LIMIT_BASE_WAIT_SECONDS = 2
      RATE_LIMIT_MAX_WAIT_SECONDS = 30

      def initialize(token:, logger: nil, cache_provider: nil, run_id: nil)
        @token = token.to_s
        @logger = logger
        @cache_provider = cache_provider
        @run_id = run_id.to_s
      end

      def token_present?
        !@token.strip.empty?
      end

      def headers
        h = { "Accept" => "application/vnd.github.v3+json", "User-Agent" => "WebTechFeeder/1.0" }
        h["Authorization"] = "Bearer #{@token}" if token_present?
        h
      end

      def get_json(path, params = {})
        with_rate_limit_retry(path) do
          resp = connection.get(path, params)
          JSON.parse(resp.body)
        end
      end

      def fetch_issue_meta(owner, repo, number, not_found_log: nil, error_log: nil)
        cache_fetch("gh_issue_meta", "#{owner}/#{repo}##{number}") do
          get_json("/repos/#{owner}/#{repo}/issues/#{number}")
        end
      rescue Faraday::ResourceNotFound
        @logger&.info("#{cid_tag}#{not_found_log}") if not_found_log
        nil
      rescue Faraday::Error, JSON::ParserError => e
        @logger&.warn("#{error_log}: #{e.message}") if error_log
        nil
      end

      def fetch_pr_meta(owner, repo, number, error_log: nil)
        cache_fetch("gh_pr_meta", "#{owner}/#{repo}##{number}") do
          get_json("/repos/#{owner}/#{repo}/pulls/#{number}")
        end
      rescue Faraday::Error, JSON::ParserError => e
        @logger&.warn("#{error_log}: #{e.message}") if error_log
        nil
      end

      def fetch_issue_comments(owner, repo, number, max_no_token:, pagination_log_tag: nil, error_log: nil, empty_on_error: [])
        mode = token_present? ? "full" : "limited"
        cache_key = "#{owner}/#{repo}##{number}:#{mode}:max#{max_no_token}"
        cache_fetch("gh_issue_comments", cache_key) do
          if token_present?
            fetch_paginated_json("/repos/#{owner}/#{repo}/issues/#{number}/comments", pagination_log_tag)
          else
            get_json("/repos/#{owner}/#{repo}/issues/#{number}/comments", per_page: max_no_token)
          end
        end
      rescue Faraday::Error, JSON::ParserError => e
        @logger&.warn("#{error_log}: #{e.message}") if error_log
        empty_on_error
      end

      def fetch_pr_files(owner, repo, number, max_no_token:, pagination_log_tag: nil, error_log: nil, empty_on_error: [])
        mode = token_present? ? "full" : "limited"
        cache_key = "#{owner}/#{repo}##{number}:#{mode}:max#{max_no_token}"
        cache_fetch("gh_pr_files", cache_key) do
          if token_present?
            fetch_paginated_json("/repos/#{owner}/#{repo}/pulls/#{number}/files", pagination_log_tag)
          else
            get_json("/repos/#{owner}/#{repo}/pulls/#{number}/files", per_page: max_no_token)
          end
        end
      rescue Faraday::Error, JSON::ParserError => e
        @logger&.warn("#{error_log}: #{e.message}") if error_log
        empty_on_error
      end

      private

      def connection
        @connection ||= Faraday.new(url: API_URL, headers: headers) do |f|
          f.request :retry, max: 3, interval: 2, backoff_factor: 2,
                            exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError,
                                         OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE, EOFError]
          f.response :raise_error
          f.adapter Faraday.default_adapter
        end
      end

      def fetch_paginated_json(path, log_tag)
        page = 1
        all = []
        tag = log_tag ? Utils::LogTagStyler.style(log_tag) : nil
        @logger&.info("#{cid_tag}#{tag} start full pagination") if log_tag
        loop do
          rows = get_json(path, per_page: 100, page: page)
          break if rows.empty?

          all.concat(rows)
          @logger&.info("#{cid_tag}#{tag} page=#{page} fetched=#{rows.size} total=#{all.size}") if log_tag
          break if rows.size < 100

          page += 1
        end
        all
      end

      def with_rate_limit_retry(path)
        retries = 0
        begin
          yield
        rescue Faraday::TooManyRequestsError, Faraday::ForbiddenError => e
          response = e.response || {}
          status = response[:status].to_i
          body = response[:body].to_s
          headers = response[:headers] || {}
          raise unless rate_limited?(status, body)

          retries += 1
          raise if retries > RATE_LIMIT_MAX_RETRIES

          wait = backoff_wait_seconds(retries, headers)
          @logger&.warn(
            "#{cid_tag}GitHub rate limit hit status=#{status} path=#{path} " \
            "retry=#{retries}/#{RATE_LIMIT_MAX_RETRIES} wait=#{wait}s"
          )
          sleep(wait)
          retry
        end
      end

      def rate_limited?(status, body)
        return true if status == 429
        return false unless status == 403

        downcased = body.downcase
        downcased.include?("secondary rate") ||
          downcased.include?("rate limit exceeded") ||
          downcased.include?("abuse detection")
      end

      def backoff_wait_seconds(retries, headers)
        retry_after = headers["retry-after"] || headers["Retry-After"]
        if retry_after.to_s.match?(/\A\d+\z/)
          parsed = retry_after.to_i
          return parsed if parsed.positive?
        end

        [RATE_LIMIT_BASE_WAIT_SECONDS * (2**(retries - 1)), RATE_LIMIT_MAX_WAIT_SECONDS].min
      end

      def cache_fetch(namespace, key, &block)
        return yield unless @cache_provider&.respond_to?(:cache_fetch)

        @cache_provider.cache_fetch(namespace, key, &block)
      end

      def cid_tag
        Utils::LogContext.tag(
          run_id: @run_id,
          show_cid: (@cache_provider&.respond_to?(:verbose_cid_logs?) && @cache_provider.verbose_cid_logs?),
          show_thread: (@cache_provider&.respond_to?(:verbose_thread_logs?) && @cache_provider.verbose_thread_logs?)
        )
      end
    end
  end
end
