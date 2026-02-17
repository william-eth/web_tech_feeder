# frozen_string_literal: true

require "time"
require_relative "base_collector"
require_relative "../section_file_filter"

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
        items = []
        logger.info("#{cid_tag}GitHub issue collector token mode: #{github_token_present? ? 'full' : 'limited'}")
        logger.info("#{cid_tag}GitHub issue collector deep_pr_crawl=#{config.deep_pr_crawl?}")

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
                              per_page: github_token_present? ? 100 : 30
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

        body_with_comments = build_body_with_comments(issue, owner, repo)
        engagement = engagement_score(issue)

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
        unless config.deep_pr_crawl?
          logger.info("#{cid_tag}[pr-compare] #{owner}/#{repo}##{issue['number']} deep PR crawl disabled")
          return nil
        end

        if issue.key?("pull_request")
          logger.info("#{cid_tag}[pr-compare] #{owner}/#{repo}##{issue['number']} direct PR compare")
          pr_compare = fetch_pr_compare(owner, repo, issue["number"])
          return nil unless pr_compare

          return "PR Compare:\n#{pr_compare}"
        end

        ref_text = [issue["body"].to_s, comments.map { |c| c["body"].to_s }.join("\n")].join("\n")
        referenced_numbers = extract_reference_numbers(ref_text, owner: owner, repo: repo)
        logger.info("#{cid_tag}[linked-pr-compare] #{owner}/#{repo}##{issue['number']} extracted_refs=#{referenced_numbers.size}")
        return nil if referenced_numbers.empty?

        blocks = []
        referenced_numbers.each do |num|
          linked = fetch_issue_meta(owner, repo, num)
          next unless linked&.key?("pull_request")

          logger.info("#{cid_tag}[linked-pr-compare] #{owner}/#{repo}##{issue['number']} resolving_pr_ref=#{num}")
          pr_compare = fetch_pr_compare(owner, repo, num)
          next unless pr_compare

          blocks << "[Linked PR ##{num}]\n#{pr_compare}"
        end

        return nil if blocks.empty?
        logger.info("#{cid_tag}[linked-pr-compare] #{owner}/#{repo}##{issue['number']} resolved_pr_refs=#{blocks.size}")

        "Linked PR Compare:\n#{blocks.join("\n\n")}"
      end

      def extract_reference_numbers(text, owner:, repo:)
        raw = text.to_s
        return [] if raw.strip.empty?

        refs = []
        refs.concat(extract_reference_numbers_from_urls(raw, owner, repo))
        refs.concat(extract_reference_numbers_from_context(raw))
        refs.concat(raw.scan(/\bGH-(\d{1,7})\b/i).flatten.map(&:to_i))

        # Ignore common non-GitHub tracker patterns (e.g., "ticket #12345")
        non_github_refs = raw.scan(/\b(?:ticket|trac|jira|redmine)\s+#(\d{1,7})\b/i).flatten.map(&:to_i)
        nums = refs.uniq - non_github_refs
        return nums if github_token_present?

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

      def fetch_issue_meta(owner, repo, number)
        cache_fetch("gh_issue_meta", "#{owner}/#{repo}##{number}") do
          conn = build_connection(GITHUB_API_URL, headers: github_headers)
          resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}")
          JSON.parse(resp.body)
        end
      rescue Faraday::ResourceNotFound
        logger.info("#{cid_tag}[linked-pr-compare] #{owner}/#{repo}##{number} not found (404), skip reference")
        nil
      rescue Faraday::Error, JSON::ParserError => e
        logger.warn("Failed to fetch issue meta for #{owner}/#{repo}##{number}: #{e.message}")
        nil
      end

      def fetch_pr_compare(owner, repo, number)
        conn = build_connection(GITHUB_API_URL, headers: github_headers)
        pr = cache_fetch("gh_pr_meta", "#{owner}/#{repo}##{number}") do
          pr_resp = conn.get("/repos/#{owner}/#{repo}/pulls/#{number}")
          JSON.parse(pr_resp.body)
        end

        files = fetch_pr_files(conn, owner, repo, number)
        format_pr_compare(pr, files)
      rescue Faraday::Error, JSON::ParserError => e
        logger.warn("Failed to fetch PR compare for #{owner}/#{repo}##{number}: #{e.message}")
        nil
      end

      def fetch_pr_files(conn, owner, repo, number)
        mode = github_token_present? ? "full" : "limited"
        cache_key = "#{owner}/#{repo}##{number}:#{mode}"
        return cache_fetch("gh_pr_files", cache_key) { fetch_pr_files_uncached(conn, owner, repo, number) }
      end

      def fetch_pr_files_uncached(conn, owner, repo, number)
        if github_token_present?
          fetch_all_pr_files(conn, owner, repo, number)
        else
          resp = conn.get("/repos/#{owner}/#{repo}/pulls/#{number}/files", per_page: MAX_PR_FILES_NO_TOKEN)
          JSON.parse(resp.body)
        end
      rescue Faraday::Error, JSON::ParserError => e
        logger.warn("Failed to fetch PR files for #{owner}/#{repo}##{number}: #{e.message}")
        []
      end

      def fetch_all_pr_files(conn, owner, repo, number)
        page = 1
        all = []
        logger.info("#{cid_tag}[pr-files] #{owner}/#{repo}##{number} start full pagination")
        loop do
          resp = conn.get("/repos/#{owner}/#{repo}/pulls/#{number}/files", per_page: 100, page: page)
          rows = JSON.parse(resp.body)
          break if rows.empty?

          all.concat(rows)
          logger.info("#{cid_tag}[pr-files] #{owner}/#{repo}##{number} page=#{page} fetched=#{rows.size} total=#{all.size}")
          break if rows.size < 100

          page += 1
        end
        all
      end

      def format_pr_compare(pr, files)
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

        filtered_files = section_filter_files(files)
        logger.info("#{cid_tag}[pr-compare] #{pr.dig('base', 'repo', 'full_name') || 'repo'}##{num} files_raw=#{files.size} files_filtered=#{filtered_files.size} section=#{@section_key || 'general'}")
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
        lines << "Section-aware files (#{@section_key || 'general'}):\n- #{file_lines.join("\n- ")}" if file_lines.any?
        lines.join("\n")
      end

      def fetch_comments(owner, repo, number)
        conn = build_connection(GITHUB_API_URL, headers: github_headers)
        mode = github_token_present? ? "full" : "limited"
        cache_key = "#{owner}/#{repo}##{number}:#{mode}"
        cache_fetch("gh_issue_comments", cache_key) do
          if github_token_present?
            fetch_all_comments(conn, owner, repo, number)
          else
            resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}/comments", per_page: MAX_COMMENTS_NO_TOKEN)
            JSON.parse(resp.body) if resp.status == 200
          end
        end
      rescue Faraday::Error, JSON::ParserError => e
        logger.warn("Failed to fetch comments for #{owner}/#{repo}##{number}: #{e.message}")
        nil
      end

      def fetch_all_comments(conn, owner, repo, number)
        page = 1
        all = []
        loop do
          resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}/comments", per_page: 100, page: page)
          rows = JSON.parse(resp.body)
          break if rows.empty?

          all.concat(rows)
          break if rows.size < 100

          page += 1
        end
        all
      end

      def github_headers
        headers = { "Accept" => "application/vnd.github.v3+json" }
        headers["Authorization"] = "Bearer #{config.github_token}" if config.github_token
        headers
      end

      def github_token_present?
        !config.github_token.to_s.strip.empty?
      end

      def section_filter_files(files)
        patterns = config.section_file_filter_patterns(@section_key)
        SectionFileFilter.apply(files, patterns)
      end

      def cache_fetch(namespace, key, &block)
        config.cache_fetch(namespace, key, &block)
      end
    end
  end
end
