# frozen_string_literal: true

require "time"
require_relative "base_collector"
require_relative "../github/pr_context_builder"

module WebTechFeeder
  module Collectors
    # Fetches notable recent issues and pull requests from GitHub repositories.
    # Focuses on high-engagement items (comments, reactions) to surface
    # community discussions worth knowing about.
    class GithubIssueCollector < BaseCollector
      # Minimum combined score (comments + reactions) to be considered "notable"
      NOTABLE_THRESHOLD = 3
      MAX_FETCH_RETRIES = 3
      MAX_COMMENTS_NO_TOKEN = 20
      MAX_PR_FILES_NO_TOKEN = 20
      MAX_LINKED_PR_REFS_NO_TOKEN = 5

      # repos: Array of { owner:, repo:, name: } hashes
      def initialize(config, repos:, section_key: nil)
        super(config)
        @repos = repos
        @section_key = section_key
      end

      def collect
        logger.info("#{cid_tag}GitHub issue collector token mode: #{github_token_present? ? 'full' : 'limited'}")
        logger.info("#{cid_tag}GitHub issue collector deep_pr_crawl=#{config.deep_pr_crawl?}")
        logger.info("#{cid_tag}GitHub issue collector max_repo_threads=#{config.max_repo_threads}")

        repo_items = parallel_map(@repos, max_threads: config.max_repo_threads) do |repo_config|
          owner = repo_config[:owner]
          repo = repo_config[:repo]
          name = repo_config[:name]

          logger.info("Fetching GitHub issues/PRs for #{owner}/#{repo}")

          issues = fetch_with_retry(owner, repo)
          next [] if issues.nil?

          notable = filter_notable(issues)
          notable.map { |issue| build_item(issue, owner, repo, name) }
        end

        repo_items.flatten.compact
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
        since = config.cutoff_time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

        # Fetch recently updated issues, sorted by most recently updated
        github_client.get_json("/repos/#{owner}/#{repo}/issues", {
                                 state: "all",
                                 sort: "updated",
                                 direction: "desc",
                                 since: since,
                                 per_page: github_token_present? ? 100 : 30
                               })
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

        body_with_comments = build_body_with_comments(issue, owner, repo)

        Item.new(
          title: "[#{type_label}] #{issue['title']}#{label_text}",
          url: issue["html_url"],
          published_at: created_at,
          body: body_with_comments,
          source: "GitHub #{type_label} - #{owner}/#{repo} (#{name})"
        )
      end

      # Fetch issue/PR body + all comments for full context
      def build_body_with_comments(issue, owner, repo)
        state = issue["state"]
        updated_at = safe_parse_time(issue["updated_at"])
        header = "State: #{state} | Comments: #{issue['comments']} | " \
                 "Reactions: #{issue.dig('reactions', 'total_count') || 0} | " \
                 "Updated: #{updated_at&.strftime('%Y-%m-%d')}\n\n"

        body = issue["body"]&.strip || ""
        comments_count = issue["comments"] || 0
        logger.info("#{cid_tag}[issue-context] #{owner}/#{repo}##{issue['number']} type=#{issue.key?('pull_request') ? 'PR' : 'Issue'} comments=#{comments_count}")

        if comments_count.zero?
          return header + truncate_body(body, max_length: 3500)
        end

        comments = fetch_comments(owner, repo, issue["number"])
        return header + truncate_body(body, max_length: 500) if comments.nil?

        parts = ["Description:\n#{body}"] if body.length.positive?
        parts ||= []
        parts << "Comments (#{comments.size}):"
        comments.each do |c|
          user = c.dig("user", "login") || "unknown"
          created = c["created_at"]
          text = c["body"].to_s.strip.gsub(/\r\n|\r/, "\n")
          parts << "[#{created}] @#{user}:\n#{text}"
        end

        compare_text = build_pr_compare_context(issue, comments, owner, repo)
        parts << compare_text if compare_text && !compare_text.empty?

        full = header + parts.join("\n\n")
        truncate_body(full, max_length: 4000)
      end

      # For PR items: include its compare summary.
      # For issue items: resolve linked references, keep only PRs, then include compare summaries.
      def build_pr_compare_context(issue, comments, owner, repo)
        WebTechFeeder::Github::PrContextBuilder.build(
          issue: issue,
          comments: comments,
          owner: owner,
          repo: repo,
          deep_pr_crawl: config.deep_pr_crawl?,
          token_present: github_token_present?,
          max_linked_refs_no_token: MAX_LINKED_PR_REFS_NO_TOKEN,
          fetch_issue_meta: lambda { |number|
            github_client.fetch_issue_meta(
              owner,
              repo,
              number,
              not_found_log: "[linked-pr-compare] #{owner}/#{repo}##{number} not found (404), skip reference",
              error_log: "Failed to fetch issue meta for #{owner}/#{repo}##{number}"
            )
          },
          fetch_pr_meta: lambda { |number|
            github_client.fetch_pr_meta(owner, repo, number, error_log: "Failed to fetch PR compare for #{owner}/#{repo}##{number}")
          },
          fetch_pr_files: lambda { |number, max_no_token, pagination_log_tag|
            github_client.fetch_pr_files(
              owner,
              repo,
              number,
              max_no_token: max_no_token,
              pagination_log_tag: pagination_log_tag,
              error_log: "Failed to fetch PR files for #{owner}/#{repo}##{number}",
              empty_on_error: []
            )
          },
          max_pr_files_no_token: MAX_PR_FILES_NO_TOKEN,
          section_key: @section_key,
          section_patterns: config.section_file_filter_patterns(@section_key),
          logger: logger,
          log_prefix: cid_tag,
          pr_compare_tag: "pr-compare",
          linked_tag: "linked-pr-compare",
          pr_files_log_tag_prefix: "pr-files"
        )
      end

      def fetch_comments(owner, repo, number)
        github_client.fetch_issue_comments(
          owner,
          repo,
          number,
          max_no_token: MAX_COMMENTS_NO_TOKEN,
          error_log: "Failed to fetch comments for #{owner}/#{repo}##{number}",
          empty_on_error: nil
        )
      end

    end
  end
end
