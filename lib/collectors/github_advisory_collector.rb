# frozen_string_literal: true

require "time"
require_relative "base_collector"

module WebTechFeeder
  module Collectors
    # Fetches recent security advisories from GitHub Advisory Database
    # for a specific ecosystem (npm, rubygems, etc.).
    # Optionally filter by package allowlist to exclude irrelevant packages.
    class GithubAdvisoryCollector < BaseCollector
      GITHUB_API_URL = "https://api.github.com"
      MAX_FETCH_RETRIES = 3

      # ecosystem: String, e.g. "npm" or "rubygems"
      # packages: optional Array of package names - only advisories affecting these packages
      def initialize(config, ecosystem:, packages: nil)
        super(config)
        @ecosystem = ecosystem
        @packages = packages
      end

      def collect
        logger.info("Fetching GitHub security advisories for ecosystem: #{@ecosystem}" \
                    "#{@packages&.any? ? " (packages: #{@packages.join(', ')})" : ''}")

        advisories = fetch_with_retry
        return [] if advisories.nil?

        items = []

        advisories.each do |advisory|
          published_at = safe_parse_time(advisory["published_at"] || advisory["updated_at"])
          next unless recent?(published_at)

          items << Item.new(
            title: advisory["summary"] || advisory["ghsa_id"],
            url: advisory["html_url"],
            published_at: published_at,
            body: truncate_body(advisory["description"] || ""),
            source: "GitHub Advisory - #{@ecosystem}"
          )
        end

        items
      end

      private

      def fetch_with_retry
        retries = 0
        loop do
          return fetch_advisories
        rescue Faraday::Error, OpenSSL::SSL::SSLError, EOFError, Errno::ECONNRESET, Errno::EPIPE => e
          retries += 1
          if retries > MAX_FETCH_RETRIES
            logger.warn("Failed to fetch advisories for #{@ecosystem} after #{MAX_FETCH_RETRIES} retries: #{e.message}")
            return nil
          end
          wait = 2 * (2**(retries - 1))
          logger.warn("Fetch failed for #{@ecosystem} advisories, retry #{retries}/#{MAX_FETCH_RETRIES} in #{wait}s: #{e.message}")
          sleep(wait)
        end
      end

      def fetch_advisories
        conn = build_connection(GITHUB_API_URL, headers: github_headers)

        params = {
          ecosystem: @ecosystem,
          per_page: 30,
          sort: "published",
          direction: "desc"
        }
        # Filter by package allowlist - only advisories affecting our tracked packages
        params[:affects] = @packages.join(",") if @packages&.any?

        response = conn.get("/advisories", params)
        JSON.parse(response.body)
      end

      def github_headers
        headers = { "Accept" => "application/vnd.github+json" }
        headers["Authorization"] = "Bearer #{config.github_token}" if config.github_token
        headers
      end
    end
  end
end
