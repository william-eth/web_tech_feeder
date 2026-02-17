# frozen_string_literal: true

require "faraday"
require "json"
require_relative "../section_file_filter"

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
          logger&.info("#{cid_tag(run_id)}GitHub enricher token mode: #{github_token_present?(github_token) ? 'full' : 'limited'}")
          logger&.info("#{cid_tag(run_id)}GitHub enricher deep_pr_crawl=#{deep_pr_crawl}")

          m = url.match(GITHUB_ISSUE_URL) || url.match(GITHUB_PR_URL)
          return nil unless m

          owner, repo, number = m[1], m[2], m[3]
          fetch_issue_with_comments(owner, repo, number, logger, github_token, section_key, section_patterns, run_id, deep_pr_crawl, cache_provider)
        rescue StandardError => e
          logger&.warn("GitHub enrich failed for #{url}: #{e.message}")
          nil
        end

        private

        def fetch_issue_with_comments(owner, repo, number, logger, github_token, section_key, section_patterns, run_id, deep_pr_crawl, cache_provider)
          conn = Faraday.new(url: "https://api.github.com") do |f|
            f.request :retry, max: 2, interval: 1, backoff_factor: 2,
                              exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
            f.adapter Faraday.default_adapter
            f.options.timeout = 15
            f.options.open_timeout = 5
            f.headers["Accept"] = "application/vnd.github.v3+json"
            f.headers["User-Agent"] = "WebTechFeeder/1.0"
            f.headers["Authorization"] = "Bearer #{github_token}" if github_token && !github_token.empty?
          end

          # Fetch issue (works for both issue and PR)
          issue = cache_fetch(cache_provider, "gh_issue_meta", "#{owner}/#{repo}##{number}") do
            issue_resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}")
            next nil unless issue_resp.status == 200

            JSON.parse(issue_resp.body)
          end
          return nil unless issue
          logger&.info("#{cid_tag(run_id)}[enricher-issue] #{owner}/#{repo}##{number} type=#{issue.key?('pull_request') ? 'PR' : 'Issue'}")

          # Fetch comments
          comments = fetch_comments(conn, owner, repo, number, github_token, logger, run_id, cache_provider)

          compare_text = build_pr_compare_context(conn, owner, repo, issue, comments, github_token, section_key, section_patterns, logger, run_id, deep_pr_crawl, cache_provider)
          format_issue_and_comments(issue, comments, compare_text, logger)
        rescue JSON::ParserError, Faraday::Error => e
          logger&.warn("GitHub API error for #{owner}/#{repo}##{number}: #{e.message}")
          nil
        end

        def fetch_comments(conn, owner, repo, number, github_token, logger, run_id, cache_provider)
          mode = github_token_present?(github_token) ? "full" : "limited"
          cache_key = "#{owner}/#{repo}##{number}:#{mode}:max#{MAX_COMMENTS_NO_TOKEN}"
          cache_fetch(cache_provider, "gh_issue_comments", cache_key) do
            if github_token_present?(github_token)
              fetch_all_comments(conn, owner, repo, number, logger, run_id)
            else
              comments_resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}/comments", per_page: MAX_COMMENTS_NO_TOKEN)
              comments_resp.status == 200 ? JSON.parse(comments_resp.body) : []
            end
          end
        end

        def fetch_all_comments(conn, owner, repo, number, logger, run_id)
          page = 1
          all = []
          logger&.info("#{cid_tag(run_id)}[enricher-comments] #{owner}/#{repo}##{number} start full pagination")
          loop do
            resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}/comments", per_page: 100, page: page)
            rows = JSON.parse(resp.body)
            break if rows.empty?

            all.concat(rows)
            logger&.info("#{cid_tag(run_id)}[enricher-comments] #{owner}/#{repo}##{number} page=#{page} fetched=#{rows.size} total=#{all.size}")
            break if rows.size < 100

            page += 1
          end
          all
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

        # For PR URLs: include PR compare.
        # For issue URLs: resolve linked references, keep only PRs, then include their compare summaries.
        def build_pr_compare_context(conn, owner, repo, issue, comments, github_token, section_key, section_patterns, logger, run_id, deep_pr_crawl, cache_provider)
          unless deep_pr_crawl
            logger&.info("#{cid_tag(run_id)}[enricher-pr-compare] #{owner}/#{repo}##{issue['number']} deep PR crawl disabled")
            return nil
          end

          if issue.key?("pull_request")
            logger&.info("#{cid_tag(run_id)}[enricher-pr-compare] #{owner}/#{repo}##{issue['number']} direct PR compare")
            pr_compare = fetch_pr_compare(conn, owner, repo, issue["number"], github_token, section_key, section_patterns, logger, run_id, cache_provider)
            return nil unless pr_compare

            return "PR Compare:\n#{pr_compare}"
          end

          ref_text = [issue["body"].to_s, comments.map { |c| c["body"].to_s }.join("\n")].join("\n")
          referenced_numbers = extract_reference_numbers(ref_text, owner: owner, repo: repo, github_token: github_token)
          logger&.info("#{cid_tag(run_id)}[enricher-linked-pr] #{owner}/#{repo}##{issue['number']} extracted_refs=#{referenced_numbers.size}")
          return nil if referenced_numbers.empty?

          blocks = []
          referenced_numbers.each do |num|
            linked = fetch_issue_meta(conn, owner, repo, num, cache_provider)
            next unless linked&.key?("pull_request")

            logger&.info("#{cid_tag(run_id)}[enricher-linked-pr] #{owner}/#{repo}##{issue['number']} resolving_pr_ref=#{num}")
            pr_compare = fetch_pr_compare(conn, owner, repo, num, github_token, section_key, section_patterns, logger, run_id, cache_provider)
            next unless pr_compare

            blocks << "[Linked PR ##{num}]\n#{pr_compare}"
          end

          return nil if blocks.empty?
          logger&.info("#{cid_tag(run_id)}[enricher-linked-pr] #{owner}/#{repo}##{issue['number']} resolved_pr_refs=#{blocks.size}")

          "Linked PR Compare:\n#{blocks.join("\n\n")}"
        end

        def extract_reference_numbers(text, owner:, repo:, github_token:)
          raw = text.to_s
          return [] if raw.strip.empty?

          refs = []
          refs.concat(extract_reference_numbers_from_urls(raw, owner, repo))
          refs.concat(extract_reference_numbers_from_context(raw))
          refs.concat(raw.scan(/\bGH-(\d{1,7})\b/i).flatten.map(&:to_i))

          non_github_refs = raw.scan(/\b(?:ticket|trac|jira|redmine)\s+#(\d{1,7})\b/i).flatten.map(&:to_i)
          nums = refs.uniq - non_github_refs
          return nums if github_token_present?(github_token)

          nums.first(MAX_LINKED_PR_REFS_NO_TOKEN)
        end

        def extract_reference_numbers_from_urls(text, owner, repo)
          escaped_owner = Regexp.escape(owner.to_s)
          escaped_repo = Regexp.escape(repo.to_s)
          pattern = %r{https?://github\.com/#{escaped_owner}/#{escaped_repo}/(?:issues|pull)/(\d+)}i
          text.scan(pattern).flatten.map(&:to_i)
        end

        def extract_reference_numbers_from_context(text)
          pattern = /
            \b(?:pr|pull\ request|pull|issue|fix(?:es|ed)?|close(?:s|d)?|resolve(?:s|d)?|ref(?:er(?:ence|ences|enced)?)?)\b
            [^#\n]{0,50}
            \#(\d{1,7})\b
          /ix
          text.scan(pattern).flatten.map(&:to_i)
        end

        def fetch_issue_meta(conn, owner, repo, number, cache_provider)
          cache_fetch(cache_provider, "gh_issue_meta", "#{owner}/#{repo}##{number}") do
            resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}")
            JSON.parse(resp.body)
          end
        rescue Faraday::ResourceNotFound
          nil
        rescue Faraday::Error, JSON::ParserError
          nil
        end

        def fetch_pr_compare(conn, owner, repo, number, github_token, section_key, section_patterns, logger, run_id, cache_provider)
          pr = cache_fetch(cache_provider, "gh_pr_meta", "#{owner}/#{repo}##{number}") do
            pr_resp = conn.get("/repos/#{owner}/#{repo}/pulls/#{number}")
            JSON.parse(pr_resp.body)
          end
          files = fetch_pr_files(conn, owner, repo, number, github_token, logger, run_id, cache_provider)
          format_pr_compare(pr, files, section_key, section_patterns, logger, run_id)
        rescue Faraday::Error, JSON::ParserError
          nil
        end

        def fetch_pr_files(conn, owner, repo, number, github_token, logger, run_id, cache_provider)
          mode = github_token_present?(github_token) ? "full" : "limited"
          cache_key = "#{owner}/#{repo}##{number}:#{mode}:max#{MAX_PR_FILES_NO_TOKEN}"
          cache_fetch(cache_provider, "gh_pr_files", cache_key) do
            if github_token_present?(github_token)
              fetch_all_pr_files(conn, owner, repo, number, logger, run_id)
            else
              resp = conn.get("/repos/#{owner}/#{repo}/pulls/#{number}/files", per_page: MAX_PR_FILES_NO_TOKEN)
              JSON.parse(resp.body)
            end
          end
        rescue Faraday::Error, JSON::ParserError
          []
        end

        def fetch_all_pr_files(conn, owner, repo, number, logger, run_id)
          page = 1
          all = []
          logger&.info("#{cid_tag(run_id)}[enricher-pr-files] #{owner}/#{repo}##{number} start full pagination")
          loop do
            resp = conn.get("/repos/#{owner}/#{repo}/pulls/#{number}/files", per_page: 100, page: page)
            rows = JSON.parse(resp.body)
            break if rows.empty?

            all.concat(rows)
            logger&.info("#{cid_tag(run_id)}[enricher-pr-files] #{owner}/#{repo}##{number} page=#{page} fetched=#{rows.size} total=#{all.size}")
            break if rows.size < 100

            page += 1
          end
          all
        end

        def format_pr_compare(pr, files, section_key, section_patterns, logger, run_id)
          num = pr["number"]
          title = pr["title"].to_s.strip
          state = pr["state"]
          merged = pr["merged_at"] ? "merged_at=#{pr['merged_at']}" : "not_merged"
          base_ref = pr.dig("base", "ref")
          head_ref = pr.dig("head", "ref")
          changed_files = pr["changed_files"] || files.size
          commits = pr["commits"] || 0
          additions = pr["additions"] || 0
          deletions = pr["deletions"] || 0
          url = pr["html_url"]

          filtered_files = section_filter_files(files, section_patterns)
          logger&.info("#{cid_tag(run_id)}[enricher-pr-compare] #{pr.dig('base', 'repo', 'full_name') || 'repo'}##{num} files_raw=#{files.size} files_filtered=#{filtered_files.size} section=#{section_key || 'general'}")
          file_lines = filtered_files.map do |f|
            name = f["filename"]
            status = f["status"]
            add = f["additions"] || 0
            del = f["deletions"] || 0
            "#{name} (#{status}, +#{add}/-#{del})"
          end

          lines = []
          lines << "PR ##{num}: #{title}"
          lines << "State: #{state}, #{merged}, base=#{base_ref}, head=#{head_ref}"
          lines << "Stats: files=#{changed_files}, commits=#{commits}, +#{additions}/-#{deletions}"
          lines << "URL: #{url}" if url
          lines << "Section-aware files (#{section_key || 'general'}):\n- #{file_lines.join("\n- ")}" if file_lines.any?
          lines.join("\n")
        end

        def truncate_for_prompt(text, max_length: 4000)
          return text if text.length <= max_length

          "#{text[0...max_length]}..."
        end

        def github_token_present?(github_token)
          !github_token.to_s.strip.empty?
        end

        def section_filter_files(files, section_patterns)
          SectionFileFilter.apply(files, section_patterns)
        end

        def cid_tag(run_id)
          rid = run_id.to_s.strip
          rid.empty? ? "" : "cid=#{rid} "
        end

        def cache_fetch(cache_provider, namespace, key, &block)
          return yield unless cache_provider&.respond_to?(:cache_fetch)

          cache_provider.cache_fetch(namespace, key, &block)
        end
      end
    end
  end
end
