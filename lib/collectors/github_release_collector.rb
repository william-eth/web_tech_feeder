# frozen_string_literal: true

require "time"
require_relative "base_collector"
require_relative "../section_file_filter"

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
    # Enriches release body with:
    # - previous-version compare summary
    # - linked PR/Issue details + comments (when references are present)
    class GithubReleaseCollector < BaseCollector
      GITHUB_API_URL = "https://api.github.com"
      MAX_FETCH_RETRIES = 3

      MAX_COMPARE_FILES = 25
      MAX_COMPARE_COMMITS = 20
      MAX_LINKED_REFERENCES = 5
      MAX_COMMENTS_PER_REFERENCE = 8
      MAX_ENRICHED_BODY = 6_000

      # repos: Array of { owner:, repo:, name: } hashes
      def initialize(config, repos:, section_key: nil)
        super(config)
        @repos = repos
        @section_key = section_key
      end

      def collect
        items = []
        logger.info("#{cid_tag}GitHub release collector token mode: #{github_token_present? ? 'full' : 'limited'}")
        logger.info("#{cid_tag}GitHub release collector deep_pr_crawl=#{config.deep_pr_crawl?}")

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
          previous_release = find_previous_release(releases, release)

          items << Item.new(
            title: "#{name} #{release['tag_name']} released",
            url: release["html_url"],
            published_at: published_at,
            body: build_release_context(owner, repo, release, previous_release),
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
        response = conn.get("/repos/#{owner}/#{repo}/releases", per_page: github_token_present? ? 100 : 15)
        JSON.parse(response.body)
      end

      def find_previous_release(releases, current_release)
        ordered = releases.sort_by do |r|
          [
            ReleaseVersion.sort_key(r["tag_name"]),
            safe_parse_time(r["published_at"]) || Time.at(0)
          ]
        end.reverse

        idx = ordered.index { |r| same_release?(r, current_release) }
        return nil unless idx

        ordered[idx + 1]
      end

      def same_release?(a, b)
        return false unless a && b

        if a["id"] && b["id"]
          a["id"] == b["id"]
        else
          a["tag_name"].to_s == b["tag_name"].to_s
        end
      end

      def build_release_context(owner, repo, release, previous_release)
        sections = []
        logger.info("#{cid_tag}[release-context] #{owner}/#{repo} tag=#{release['tag_name']} prev_tag=#{previous_release&.dig('tag_name') || 'n/a'}")

        body = release["body"].to_s.strip
        sections << "Release Notes:\n#{body}" unless body.empty?

        compare = fetch_compare_summary(owner, repo, previous_release&.dig("tag_name"), release["tag_name"])
        sections << compare if compare

        if config.deep_pr_crawl?
          refs = extract_references([body, compare].compact.join("\n"), owner: owner, repo: repo)
          logger.info("#{cid_tag}[release-context] #{owner}/#{repo} extracted_refs=#{refs.size}")
          linked = fetch_linked_references(owner, repo, refs)
          sections << linked if linked
        else
          logger.info("#{cid_tag}[release-context] #{owner}/#{repo} deep PR crawl disabled; skip linked PR/Issue references")
        end

        final_text = sections.join("\n\n")
        truncate_body(final_text, max_length: MAX_ENRICHED_BODY)
      end

      def fetch_compare_summary(owner, repo, previous_tag, current_tag)
        return nil if previous_tag.to_s.empty? || current_tag.to_s.empty?

        conn = build_connection(GITHUB_API_URL, headers: github_headers)
        resp = conn.get("/repos/#{owner}/#{repo}/compare/#{previous_tag}...#{current_tag}")
        data = JSON.parse(resp.body)

        commits = limit_for_no_token(data["commits"] || [], MAX_COMPARE_COMMITS)
        files = limit_for_no_token(data["files"] || [], MAX_COMPARE_FILES)
        filtered_files = section_filter_files(files)
        logger.info("#{cid_tag}[compare] #{owner}/#{repo} #{previous_tag}...#{current_tag} commits=#{commits.size} files_raw=#{files.size} files_filtered=#{filtered_files.size} section=#{@section_key || 'general'}")

        parts = []
        parts << "Compare: #{previous_tag}...#{current_tag}"
        parts << "Commits: #{data['total_commits'] || commits.size}, Files changed: #{files.size}"
        parts << "Compare URL: #{data['html_url']}" if data["html_url"]

        if filtered_files.any?
          file_list = filtered_files.map do |f|
            path = f["filename"]
            status = f["status"]
            additions = f["additions"] || 0
            deletions = f["deletions"] || 0
            "#{path} (#{status}, +#{additions}/-#{deletions})"
          end
          parts << "Section-aware files (#{@section_key || 'general'}):\n- #{file_list.join("\n- ")}"
        end

        if commits.any?
          commit_lines = commits.map do |c|
            sha = c["sha"].to_s[0, 7]
            msg = c.dig("commit", "message").to_s.lines.first.to_s.strip
            "#{sha} #{msg}"
          end
          parts << "Commit headlines:\n- #{commit_lines.join("\n- ")}"
        end

        parts.join("\n")
      rescue Faraday::Error, JSON::ParserError => e
        logger.warn("Failed compare #{owner}/#{repo} #{previous_tag}...#{current_tag}: #{e.message}")
        nil
      end

      def extract_references(text, owner:, repo:)
        raw = text.to_s
        return [] if raw.strip.empty?

        refs = []
        refs.concat(extract_reference_numbers_from_urls(raw, owner, repo))
        refs.concat(extract_reference_numbers_from_context(raw))
        refs.concat(raw.scan(/\bGH-(\d{1,7})\b/i).flatten.map(&:to_i))

        non_github_refs = raw.scan(/\b(?:ticket|trac|jira|redmine)\s+#(\d{1,7})\b/i).flatten.map(&:to_i)
        refs = refs.uniq - non_github_refs
        limit_for_no_token(refs, MAX_LINKED_REFERENCES)
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

      def fetch_linked_references(owner, repo, numbers)
        return nil if numbers.empty?
        logger.info("#{cid_tag}[linked-refs] #{owner}/#{repo} resolving=#{numbers.size}")

        conn = build_connection(GITHUB_API_URL, headers: github_headers)
        blocks = []

        numbers.each do |number|
          issue = fetch_issue(conn, owner, repo, number)
          next unless issue

          comments = fetch_issue_comments(conn, owner, repo, number)
          blocks << format_issue_block(issue, comments)
        end

        return nil if blocks.empty?
        logger.info("#{cid_tag}[linked-refs] #{owner}/#{repo} resolved=#{blocks.size}")

        "Linked PR/Issue references:\n#{blocks.join("\n\n")}"
      end

      def fetch_issue(conn, owner, repo, number)
        cache_fetch("gh_issue_meta", "#{owner}/#{repo}##{number}") do
          resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}")
          JSON.parse(resp.body)
        end
      rescue Faraday::ResourceNotFound
        logger.info("#{cid_tag}[linked-refs] #{owner}/#{repo}##{number} not found (404), skip reference")
        nil
      rescue Faraday::Error, JSON::ParserError => e
        logger.warn("Failed to fetch linked issue #{owner}/#{repo}##{number}: #{e.message}")
        nil
      end

      def fetch_issue_comments(conn, owner, repo, number)
        mode = github_token_present? ? "full" : "limited"
        cache_key = "#{owner}/#{repo}##{number}:#{mode}:max#{MAX_COMMENTS_PER_REFERENCE}"
        cache_fetch("gh_issue_comments", cache_key) do
          if github_token_present?
            fetch_all_issue_comments(conn, owner, repo, number)
          else
            resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}/comments", per_page: MAX_COMMENTS_PER_REFERENCE)
            JSON.parse(resp.body)
          end
        end
      rescue Faraday::Error, JSON::ParserError => e
        logger.warn("Failed to fetch linked issue comments #{owner}/#{repo}##{number}: #{e.message}")
        []
      end

      def fetch_all_issue_comments(conn, owner, repo, number)
        page = 1
        all = []
        logger.info("#{cid_tag}[linked-comments] #{owner}/#{repo}##{number} start full pagination")
        loop do
          resp = conn.get("/repos/#{owner}/#{repo}/issues/#{number}/comments", per_page: 100, page: page)
          rows = JSON.parse(resp.body)
          break if rows.empty?

          all.concat(rows)
          logger.info("#{cid_tag}[linked-comments] #{owner}/#{repo}##{number} page=#{page} fetched=#{rows.size} total=#{all.size}")
          break if rows.size < 100

          page += 1
        end
        all
      end

      def format_issue_block(issue, comments)
        number = issue["number"]
        type = issue.key?("pull_request") ? "PR" : "Issue"
        title = issue["title"].to_s.strip
        state = issue["state"]
        url = issue["html_url"]
        labels = (issue["labels"] || []).map { |l| l["name"] }.compact
        label_text = labels.empty? ? "" : " [#{labels.join(', ')}]"

        issue_body = issue["body"].to_s.strip
        issue_body = truncate_body(issue_body, max_length: 600) unless issue_body.empty?

        comment_lines = comments.map do |c|
          user = c.dig("user", "login") || "unknown"
          created = c["created_at"]
          text = c["body"].to_s.gsub(/\s+/, " ").strip
          "- [#{created}] @#{user}: #{truncate_body(text, max_length: 280)}"
        end

        block = +"[#{type} ##{number}] #{title}#{label_text}\nState: #{state}\nURL: #{url}"
        block << "\nBody: #{issue_body}" unless issue_body.empty?
        block << "\nComments:\n#{comment_lines.join("\n")}" if comment_lines.any?
        block
      end

      def github_headers
        headers = { "Accept" => "application/vnd.github.v3+json" }
        headers["Authorization"] = "Bearer #{config.github_token}" if config.github_token
        headers
      end

      def github_token_present?
        !config.github_token.to_s.strip.empty?
      end

      def limit_for_no_token(arr, limit)
        return arr if github_token_present?

        arr.first(limit)
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
