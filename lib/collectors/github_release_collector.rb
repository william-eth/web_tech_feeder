# frozen_string_literal: true

require "time"
require_relative "base_collector"

module WebTechFeeder
  module Collectors
    # Parses tag_name (e.g. v1.0.0, v16.2.0-canary.37) for semantic version comparison.
    # Returns a sortable key: higher version => higher key. Invalid tags sort last.
    module ReleaseVersion
      module_function

      def sort_key(tag_name)
        return [0, tag_name.to_s] if tag_name.nil? || tag_name.to_s.strip.empty?

        cleaned = tag_name.to_s.strip.sub(/\Av/i, "")
        ver = Gem::Version.new(cleaned)
        [1, ver]
      rescue ArgumentError
        [0, tag_name.to_s]
      end
    end
    # Fetches recent releases from GitHub repositories via the REST API.
    # Supports GITHUB_TOKEN for higher rate limits.
    class GithubReleaseCollector < BaseCollector
      GITHUB_API_URL = "https://api.github.com"
      MAX_FETCH_RETRIES = 3

      # repos: Array of { owner:, repo:, name: } hashes
      def initialize(config, repos:)
        super(config)
        @repos = repos
      end

      def collect
        items = []

        @repos.each do |repo_config|
          owner = repo_config[:owner]
          repo = repo_config[:repo]
          name = repo_config[:name]

          logger.info("Fetching GitHub releases for #{owner}/#{repo}")
          releases = fetch_with_retry(owner, repo)
          next if releases.nil?

          # Keep only the latest release per repo (by version, not published_at)
          # Prefer highest semver (v2.0.0 over v1.9.1); use published_at as tiebreaker
          recent_releases = releases
            .map { |r| [r, safe_parse_time(r["published_at"])] }
            .select { |_r, published_at| recent?(published_at) }

          latest = recent_releases.max_by do |r, published_at|
            tag = r["tag_name"]
            published = published_at || Time.at(0)
            [ReleaseVersion.sort_key(tag), published]
          end
          next unless latest

          release, published_at = latest
          items << Item.new(
            title: "#{name} #{release['tag_name']} released",
            url: release["html_url"],
            published_at: published_at,
            body: truncate_body(release["body"]),
            source: "GitHub - #{owner}/#{repo}"
          )
        end

        items
      end

      private

      def fetch_with_retry(owner, repo)
        retries = 0
        loop do
          return fetch_releases(owner, repo)
        rescue Faraday::Error, OpenSSL::SSL::SSLError, EOFError, Errno::ECONNRESET, Errno::EPIPE => e
          retries += 1
          if retries > MAX_FETCH_RETRIES
            logger.warn("Failed to fetch releases for #{owner}/#{repo} after #{MAX_FETCH_RETRIES} retries: #{e.message}")
            return nil
          end
          wait = 2 * (2**(retries - 1))
          logger.warn("Fetch failed for #{owner}/#{repo}, retry #{retries}/#{MAX_FETCH_RETRIES} in #{wait}s: #{e.message}")
          sleep(wait)
        end
      end

      def fetch_releases(owner, repo)
        conn = build_connection(GITHUB_API_URL, headers: github_headers)
        response = conn.get("/repos/#{owner}/#{repo}/releases", per_page: 15)
        JSON.parse(response.body)
      end

      def github_headers
        headers = { "Accept" => "application/vnd.github.v3+json" }
        headers["Authorization"] = "Bearer #{config.github_token}" if config.github_token
        headers
      end
    end
  end
end
