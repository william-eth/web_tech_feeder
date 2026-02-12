# frozen_string_literal: true

require "time"
require_relative "base_collector"

module WebTechFeeder
  module Collectors
    # Fetches notable recent issues and pull requests from GitHub repositories.
    # Focuses on high-engagement items (comments, reactions) to surface
    # community discussions worth knowing about.
    class GithubIssueCollector < BaseCollector
      GITHUB_API_URL = "https://api.github.com"

      # Minimum combined score (comments + reactions) to be considered "notable"
      NOTABLE_THRESHOLD = 3
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

          logger.info("Fetching GitHub issues/PRs for #{owner}/#{repo}")

          issues = fetch_with_retry(owner, repo)
          next if issues.nil?

          notable = filter_notable(issues)
          notable.each do |issue|
            items << build_item(issue, owner, repo, name)
          end
        end

        items
      end

      private

      def fetch_with_retry(owner, repo)
        retries = 0

        loop do
          return fetch_issues(owner, repo)
        rescue Faraday::Error, OpenSSL::SSL::SSLError, EOFError, Errno::ECONNRESET, Errno::EPIPE => e
          retries += 1
          if retries > MAX_FETCH_RETRIES
            logger.warn("Failed to fetch issues for #{owner}/#{repo} after #{MAX_FETCH_RETRIES} retries: #{e.message}")
            return nil
          end

          wait = 2 * (2**(retries - 1))
          logger.warn("Fetch failed for #{owner}/#{repo}, retry #{retries}/#{MAX_FETCH_RETRIES} in #{wait}s: #{e.message}")
          sleep(wait)
        end
      end

      def fetch_issues(owner, repo)
        conn = build_connection(GITHUB_API_URL, headers: github_headers)
        since = config.cutoff_time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

        # Fetch recently updated issues, sorted by most recently updated
        response = conn.get("/repos/#{owner}/#{repo}/issues", {
                              state: "all",
                              sort: "updated",
                              direction: "desc",
                              since: since,
                              per_page: 30
                            })
        JSON.parse(response.body)
      end

      # Filter to only notable issues (high engagement or labeled important)
      def filter_notable(issues)
        issues.select do |issue|
          engagement_score(issue) >= NOTABLE_THRESHOLD || notable_labels?(issue)
        end
      end

      def engagement_score(issue)
        comments = issue["comments"] || 0
        reactions = issue.dig("reactions", "total_count") || 0
        comments + reactions
      end

      def notable_labels?(issue)
        labels = (issue["labels"] || []).map { |l| l["name"].to_s.downcase }
        notable_keywords = %w[security breaking-change bug critical important release announcement]
        labels.any? { |label| notable_keywords.any? { |kw| label.include?(kw) } }
      end

      def build_item(issue, owner, repo, name)
        is_pr = issue.key?("pull_request")
        type_label = is_pr ? "PR" : "Issue"
        state = issue["state"]
        created_at = safe_parse_time(issue["created_at"])
        updated_at = safe_parse_time(issue["updated_at"])

        labels = (issue["labels"] || []).map { |l| l["name"] }.join(", ")
        label_text = labels.empty? ? "" : " [#{labels}]"

        body_preview = truncate_body(issue["body"] || "", max_length: 500)
        engagement = engagement_score(issue)

        Item.new(
          title: "[#{type_label}] #{issue['title']}#{label_text}",
          url: issue["html_url"],
          published_at: created_at,
          body: "State: #{state} | Comments: #{issue['comments']} | " \
                "Reactions: #{issue.dig('reactions', 'total_count') || 0} | " \
                "Updated: #{updated_at&.strftime('%Y-%m-%d')}\n#{body_preview}",
          source: "GitHub #{type_label} - #{owner}/#{repo} (#{name})"
        )
      end

      def github_headers
        headers = { "Accept" => "application/vnd.github.v3+json" }
        headers["Authorization"] = "Bearer #{config.github_token}" if config.github_token
        headers
      end
    end
  end
end
