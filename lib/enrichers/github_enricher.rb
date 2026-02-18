# frozen_string_literal: true

require_relative "../github/client"
require_relative "../github/pr_context_builder"
require_relative "../utils/log_context"
require_relative "../utils/text_truncator"

module WebTechFeeder
  module Enrichers
    # Fetches full issue/PR + comments from GitHub API.
    # Used to enrich RSS entries linking to github.com/{owner}/{repo}/issues/{n} or /pull/{n}.
    class GithubEnricher
      GITHUB_ISSUE_URL = %r{\Ahttps?://(?:www\.)?github\.com/([^/]+)/([^/]+)/issues/(\d+)(?:\?\S*)?\z}i
      GITHUB_PR_URL   = %r{\Ahttps?://(?:www\.)?github\.com/([^/]+)/([^/]+)/pull/(\d+)(?:\?\S*)?\z}i
      MAX_COMMENTS_NO_TOKEN = 20
      MAX_PR_FILES_NO_TOKEN = 20
      MAX_LINKED_PR_REFS_NO_TOKEN = 5

      class << self
        def match?(url)
          url.to_s.match?(GITHUB_ISSUE_URL) || url.to_s.match?(GITHUB_PR_URL)
        end

        def enrich(url, logger: nil, github_token: nil, section_key: nil, section_patterns: nil, run_id: nil, deep_pr_crawl: true, cache_provider: nil)
          return nil unless match?(url)
          client = build_client(github_token, logger, cache_provider, run_id)
          logger&.info("#{cid_tag(run_id, cache_provider)}GitHub enricher token mode: #{client.token_present? ? 'full' : 'limited'}")
          logger&.info("#{cid_tag(run_id, cache_provider)}GitHub enricher deep_pr_crawl=#{deep_pr_crawl}")

          m = url.match(GITHUB_ISSUE_URL) || url.match(GITHUB_PR_URL)
          return nil unless m

          owner, repo, number = m[1], m[2], m[3]
          fetch_issue_with_comments(client, owner, repo, number, logger, section_key, section_patterns, run_id, deep_pr_crawl, cache_provider)
        rescue StandardError => e
          logger&.warn("GitHub enrich failed for #{url}: #{e.message}")
          nil
        end

        private

        def fetch_issue_with_comments(client, owner, repo, number, logger, section_key, section_patterns, run_id, deep_pr_crawl, cache_provider)
          # Fetch issue (works for both issue and PR)
          issue = client.fetch_issue_meta(
            owner,
            repo,
            number,
            error_log: "GitHub issue fetch failed for #{owner}/#{repo}##{number}"
          )
          return nil unless issue
          logger&.info("#{cid_tag(run_id, cache_provider)}[enricher-issue] #{owner}/#{repo}##{number} type=#{issue.key?('pull_request') ? 'PR' : 'Issue'}")

          # Fetch comments
          comments = fetch_comments(client, owner, repo, number)

          compare_text = WebTechFeeder::Github::PrContextBuilder.build(
            issue: issue,
            comments: comments,
            owner: owner,
            repo: repo,
            deep_pr_crawl: deep_pr_crawl,
            token_present: client.token_present?,
            max_linked_refs_no_token: MAX_LINKED_PR_REFS_NO_TOKEN,
            fetch_issue_meta: lambda { |linked_number|
              client.fetch_issue_meta(
                owner,
                repo,
                linked_number,
                error_log: "GitHub linked issue fetch failed for #{owner}/#{repo}##{linked_number}"
              )
            },
            fetch_pr_meta: lambda { |pr_number|
              client.fetch_pr_meta(
                owner,
                repo,
                pr_number,
                error_log: "GitHub PR fetch failed for #{owner}/#{repo}##{pr_number}"
              )
            },
            fetch_pr_files: lambda { |pr_number, max_no_token, pagination_log_tag|
              client.fetch_pr_files(
                owner,
                repo,
                pr_number,
                max_no_token: max_no_token,
                pagination_log_tag: pagination_log_tag,
                empty_on_error: []
              )
            },
            max_pr_files_no_token: MAX_PR_FILES_NO_TOKEN,
            section_key: section_key,
            section_patterns: section_patterns,
            logger: logger,
            log_prefix: cid_tag(run_id, cache_provider),
            pr_compare_tag: "enricher-pr-compare",
            linked_tag: "enricher-linked-pr",
            pr_files_log_tag_prefix: "enricher-pr-files"
          )
          format_issue_and_comments(issue, comments, compare_text, logger)
        rescue StandardError => e
          logger&.warn("GitHub API error for #{owner}/#{repo}##{number}: #{e.message}")
          nil
        end

        def fetch_comments(client, owner, repo, number)
          client.fetch_issue_comments(
            owner,
            repo,
            number,
            max_no_token: MAX_COMMENTS_NO_TOKEN,
            pagination_log_tag: "enricher-comments #{owner}/#{repo}##{number}",
            error_log: "GitHub comment fetch failed for #{owner}/#{repo}##{number}",
            empty_on_error: []
          )
        end

        def format_issue_and_comments(issue, comments, compare_text, logger)
          parts = []

          # Issue/PR body
          body = issue["body"]&.strip
          parts << "Description:\n#{body}" if body && !body.empty?

          # Comments
          if comments.any?
            parts << "Comments (#{comments.size}):"
            comments.each do |c|
              user = c.dig("user", "login") || "unknown"
              created = c["created_at"]
              text = c["body"].to_s.strip.gsub(/\r\n|\r/, "\n")
              parts << "[#{created}] @#{user}:\n#{text}"
            end
          end

          parts << compare_text if compare_text && !compare_text.empty?

          return nil if parts.empty?

          result = parts.join("\n\n")
          truncate_for_prompt(result, max_length: 4000)
        end

        def truncate_for_prompt(text, max_length: 4000)
          Utils::TextTruncator.truncate(text, max_length: max_length)
        end

        def cid_tag(run_id, cache_provider)
          Utils::LogContext.tag(
            run_id: run_id,
            show_cid: (cache_provider&.respond_to?(:verbose_cid_logs?) && cache_provider.verbose_cid_logs?),
            show_thread: (cache_provider&.respond_to?(:verbose_thread_logs?) && cache_provider.verbose_thread_logs?)
          )
        end

        def build_client(github_token, logger, cache_provider, run_id)
          WebTechFeeder::Github::Client.new(
            token: github_token,
            logger: logger,
            cache_provider: cache_provider,
            run_id: run_id
          )
        end
      end
    end
  end
end
