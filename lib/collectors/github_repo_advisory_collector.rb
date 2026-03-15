# frozen_string_literal: true

require "time"
require_relative "base_collector"

module WebTechFeeder
  module Collectors
    # Fetches recent security advisories from specific GitHub repositories
    # (e.g. valkey-io/valkey, postgres/postgres) since they don't belong to
    # a specific ecosystem in the global advisory database.
    class GithubRepoAdvisoryCollector < BaseCollector
      GITHUB_API_URL = "https://api.github.com"
      MAX_FETCH_RETRIES = 3

      # repos: Array of Hashes e.g. [{ owner: "valkey-io", repo: "valkey", name: "Valkey" }]
      def initialize(config, repos:)
        super(config)
        @repos = repos
      end

      def collect
        logger.info("Fetching GitHub repository security advisories for #{@repos.size} repos")
        items = []

        @repos.each do |repo_config|
          owner = repo_config[:owner]
          repo = repo_config[:repo]
          name = repo_config[:name]

          advisories = fetch_with_retry(owner, repo)
          next if advisories.nil? || advisories.empty?

          advisories.each do |advisory|
            published_at = safe_parse_time(advisory["published_at"] || advisory["updated_at"])
            next unless recent?(published_at)

            items << Item.new(
              title: advisory["summary"] || advisory["ghsa_id"],
              url: advisory["html_url"],
              published_at: published_at,
              body: truncate_body(advisory["description"] || ""),
              source: "GitHub Advisory - #{name}",
              metadata: extract_advisory_metadata(advisory)
            )
          end
        end

        items
      end

      private

      def fetch_with_retry(owner, repo)
        retries = 0
        loop do
          return fetch_advisories(owner, repo)
        rescue Faraday::Error, OpenSSL::SSL::SSLError, EOFError, Errno::ECONNRESET, Errno::EPIPE => e
          retries += 1
          if retries > MAX_FETCH_RETRIES
            logger.warn("Failed to fetch repo advisories for #{owner}/#{repo} after #{MAX_FETCH_RETRIES} retries: #{e.message}")
            return nil
          end
          wait = 2 * (2**(retries - 1))
          logger.warn("Fetch failed for repo advisories #{owner}/#{repo}, retry #{retries}/#{MAX_FETCH_RETRIES} in #{wait}s: #{e.message}")
          sleep(wait)
        end
      end

      def fetch_advisories(owner, repo)
        conn = build_connection(GITHUB_API_URL, headers: github_headers)

        params = {
          per_page: 30,
          sort: "published",
          direction: "desc"
        }

        response = conn.get("/repos/#{owner}/#{repo}/security-advisories", params)

        # If the repository doesn't have security advisories enabled, it returns 404
        return [] if response.status == 404

        JSON.parse(response.body)
      end

      def extract_advisory_metadata(advisory)
        cvss = advisory.dig("cvss", "score")
        severity = advisory["severity"]
        cve_id = advisory["cve_id"]

        vulns = Array(advisory["vulnerabilities"]).map do |v|
          pkg = v.dig("package", "name")
          {
            package: pkg,
            vulnerable_range: v["vulnerable_version_range"],
            patched_version: v.dig("first_patched_version", "identifier")
          }.compact
        end.reject(&:empty?)

        meta = { severity: severity }
        meta[:cvss_score] = cvss if cvss
        meta[:cve_id] = cve_id if cve_id
        meta[:vulnerabilities] = vulns if vulns.any?
        meta
      end

      def github_headers
        headers = { "Accept" => "application/vnd.github+json" }
        headers["Authorization"] = "Bearer #{config.github_token}" if config.github_token
        headers
      end
    end
  end
end
