# frozen_string_literal: true

require "time"
require "base64"
require_relative "base_collector"
require_relative "../section_file_filter"
require_relative "../github/reference_extractor"
require_relative "../utils/log_tag_styler"

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
      MAX_FETCH_RETRIES = 3

      MAX_COMPARE_FILES = 25
      MAX_COMPARE_COMMITS = 20
      MAX_LINKED_REFERENCES = 5
      MAX_COMMENTS_PER_REFERENCE = 8
      MAX_ENRICHED_BODY = 6_000
      MAX_TAGS_SCAN = 20
      DEFAULT_RELEASE_NOTES_FILES = %w[CHANGELOG.md CHANGES.md Changes.md HISTORY.md RELEASE_NOTES.md].freeze

      # repos: Array of { owner:, repo:, name: } hashes
      def initialize(config, repos:, section_key: nil)
        super(config)
        @repos = repos
        @section_key = section_key
      end

      def collect
        logger.info("#{cid_tag}GitHub release collector token mode: #{github_token_present? ? 'full' : 'limited'}")
        logger.info("#{cid_tag}GitHub release collector deep_pr_crawl=#{config.deep_pr_crawl?}")
        logger.info("#{cid_tag}GitHub release collector max_repo_threads=#{config.max_repo_threads}")

        repo_items = parallel_map(@repos, max_threads: config.max_repo_threads) do |repo_config|
          owner = repo_config[:owner]
          repo = repo_config[:repo]
          name = repo_config[:name]
          strategy = release_strategy(repo_config)

          logger.info("Fetching GitHub versions for #{owner}/#{repo} (strategy=#{strategy})")
          releases = fetch_with_retry(owner, repo) unless strategy == "tags_only"

          current_release, previous_release, published_at = select_latest_release_pair(releases)
          if current_release.nil? && strategy != "releases_only"
            logger.info("#{cid_tag}#{styled_tag('release-context')} #{owner}/#{repo} release data empty; fallback to tags")
            current_release, previous_release, published_at = select_latest_tag_pair(owner, repo)
          end
          next nil unless current_release

          current_release = current_release.dup
          current_release["body"] = merge_release_notes(
            owner: owner,
            repo: repo,
            current_release: current_release,
            previous_release: previous_release,
            repo_config: repo_config
          )

          Item.new(
            title: "#{name} #{current_release['tag_name']} released",
            url: current_release["html_url"],
            published_at: published_at,
            body: build_release_context(owner, repo, current_release, previous_release),
            source: "GitHub - #{owner}/#{repo}"
          )
        end

        repo_items.compact
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
        github_client.get_json("/repos/#{owner}/#{repo}/releases", per_page: github_token_present? ? 100 : 15)
      end

      def fetch_tags(owner, repo)
        github_client.get_json("/repos/#{owner}/#{repo}/tags", per_page: github_token_present? ? 100 : MAX_TAGS_SCAN)
      rescue Faraday::Error, JSON::ParserError => e
        logger.warn("Failed to fetch tags for #{owner}/#{repo}: #{e.message}")
        []
      end

      def select_latest_release_pair(releases)
        return [nil, nil, nil] unless releases.is_a?(Array)

        recent_releases = releases
                          .map { |r| [r, safe_parse_time(r["published_at"])] }
                          .select { |_r, published_at| recent?(published_at) }
        latest = recent_releases.max_by do |r, published_at|
          tag = r["tag_name"]
          published = published_at || Time.at(0)
          [ReleaseVersion.sort_key(tag), published]
        end
        return [nil, nil, nil] unless latest

        release, published_at = latest
        previous_release = find_previous_release(releases, release)
        [release, previous_release, published_at]
      end

      def select_latest_tag_pair(owner, repo)
        tags = fetch_tags(owner, repo)
        return [nil, nil, nil] if tags.empty?

        enriched = tags.first(MAX_TAGS_SCAN).map do |tag|
          tag_name = tag["name"].to_s
          published_at = fetch_tag_commit_time(owner, repo, tag)
          [tag, published_at]
        end.select { |_tag, published_at| recent?(published_at) }
        return [nil, nil, nil] if enriched.empty?

        latest_tag, published_at = enriched.max_by do |tag, at|
          [ReleaseVersion.sort_key(tag["name"]), at || Time.at(0)]
        end
        sorted = enriched.sort_by do |tag, at|
          [ReleaseVersion.sort_key(tag["name"]), at || Time.at(0)]
        end.reverse
        idx = sorted.index { |t, _at| t["name"].to_s == latest_tag["name"].to_s }
        previous_tag = idx ? sorted[idx + 1]&.first : nil

        current_release = {
          "tag_name" => latest_tag["name"],
          "body" => "",
          "html_url" => "https://github.com/#{owner}/#{repo}/tree/#{latest_tag['name']}"
        }
        previous_release = previous_tag ? { "tag_name" => previous_tag["name"] } : nil
        [current_release, previous_release, published_at]
      end

      def fetch_tag_commit_time(owner, repo, tag)
        sha = tag.dig("commit", "sha").to_s
        return nil if sha.empty?

        cache_key = "#{owner}/#{repo}@#{sha}"
        config.cache_fetch("gh_tag_commit_time", cache_key) do
          commit = github_client.get_json("/repos/#{owner}/#{repo}/commits/#{sha}")
          safe_parse_time(commit.dig("commit", "committer", "date"))
        rescue Faraday::Error, JSON::ParserError
          nil
        end
      end

      def merge_release_notes(owner:, repo:, current_release:, previous_release:, repo_config:)
        base_body = current_release["body"].to_s.strip
        notes_excerpt = fetch_release_notes_excerpt(
          owner: owner,
          repo: repo,
          current_tag: current_release["tag_name"],
          previous_tag: previous_release&.dig("tag_name"),
          repo_config: repo_config
        )
        return base_body if notes_excerpt.to_s.strip.empty?
        return notes_excerpt if base_body.empty?

        "#{base_body}\n\n#{notes_excerpt}"
      end

      def fetch_release_notes_excerpt(owner:, repo:, current_tag:, previous_tag:, repo_config:)
        files = release_notes_files(repo_config)
        files.each do |file_path|
          content = fetch_repo_text_file(owner, repo, file_path)
          next if content.to_s.strip.empty?

          section = extract_version_section(content, current_tag, previous_tag)
          next if section.to_s.strip.empty?

          logger.info("#{cid_tag}#{styled_tag('release-context')} #{owner}/#{repo} release notes matched from #{file_path}")
          return "Changelog (#{file_path}):\n#{truncate_body(section, max_length: 2500)}"
        end
        ""
      end

      def release_notes_files(repo_config)
        files = repo_config[:release_notes_files]
        return DEFAULT_RELEASE_NOTES_FILES unless files.is_a?(Array) && files.any?

        files.map(&:to_s)
      end

      def release_strategy(repo_config)
        raw = repo_config[:release_strategy].to_s.downcase
        return "releases_only" if raw == "releases_only"
        return "tags_only" if raw == "tags_only"

        "auto"
      end

      def fetch_repo_text_file(owner, repo, path)
        cache_key = "#{owner}/#{repo}:#{path}"
        config.cache_fetch("gh_repo_text_file", cache_key) do
          data = github_client.get_json("/repos/#{owner}/#{repo}/contents/#{path}")
          next "" unless data.is_a?(Hash) && data["encoding"].to_s.downcase == "base64"

          Base64.decode64(data["content"].to_s)
        rescue Faraday::ResourceNotFound
          ""
        rescue Faraday::Error, JSON::ParserError
          ""
        end
      end

      def extract_version_section(text, current_tag, previous_tag)
        current_variants = tag_variants(current_tag)
        previous_variants = tag_variants(previous_tag)
        lines = text.to_s.gsub("\r\n", "\n").split("\n")
        return "" if lines.empty?

        start_idx = find_version_start(lines, current_variants)
        return "" unless start_idx

        end_idx = find_version_end(lines, start_idx + 1, previous_variants)
        slice = lines[start_idx...(end_idx || lines.length)]
        slice.join("\n").strip
      end

      def find_version_start(lines, variants)
        lines.each_with_index do |line, idx|
          stripped = line.strip
          next if stripped.empty?

          return idx if variants.any? { |v| heading_match?(stripped, v) }
        end
        nil
      end

      def find_version_end(lines, from_idx, previous_variants)
        idx = from_idx
        while idx < lines.length
          stripped = lines[idx].strip
          if previous_variants.any? { |v| heading_match?(stripped, v) } ||
             (looks_like_version_heading?(stripped) && (
               stripped.start_with?("#") ||
               (idx + 1 < lines.length && lines[idx + 1].strip.match?(/\A[-=]{3,}\z/))
             ))
            return idx
          end
          idx += 1
        end
        nil
      end

      def heading_match?(line, version_text)
        clean = version_text.to_s.strip
        return false if clean.empty?

        escaped = Regexp.escape(clean)
        line.match?(/\A(?:\#{1,6}\s*)?#{escaped}\s*\z/)
      end

      def looks_like_version_heading?(line)
        line.match?(/\A(?:\#{1,6}\s*)?v?\d+\.\d+\.\d+(?:[-.\w]*)\z/)
      end

      def tag_variants(tag)
        raw = tag.to_s.strip
        return [] if raw.empty?

        no_v = raw.sub(/\Av/i, "")
        [raw, no_v, "v#{no_v}"].uniq
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
        logger.info("#{cid_tag}#{styled_tag('release-context')} #{owner}/#{repo} tag=#{release['tag_name']} prev_tag=#{previous_release&.dig('tag_name') || 'n/a'}")

        body = release["body"].to_s.strip
        sections << "Release Notes:\n#{body}" unless body.empty?

        compare = fetch_compare_summary(owner, repo, previous_release&.dig("tag_name"), release["tag_name"])
        sections << compare if compare

        if config.deep_pr_crawl?
          refs = extract_references([body, compare].compact.join("\n"), owner: owner, repo: repo)
          logger.info("#{cid_tag}#{styled_tag('release-context')} #{owner}/#{repo} extracted_refs=#{refs.size}")
          linked = fetch_linked_references(owner, repo, refs)
          sections << linked if linked
        else
          logger.info("#{cid_tag}#{styled_tag('release-context')} #{owner}/#{repo} deep PR crawl disabled; skip linked PR/Issue references")
        end

        final_text = sections.join("\n\n")
        truncate_body(final_text, max_length: MAX_ENRICHED_BODY)
      end

      def fetch_compare_summary(owner, repo, previous_tag, current_tag)
        return nil if previous_tag.to_s.empty? || current_tag.to_s.empty?

        data = github_client.get_json("/repos/#{owner}/#{repo}/compare/#{previous_tag}...#{current_tag}")

        commits = limit_for_no_token(data["commits"] || [], MAX_COMPARE_COMMITS)
        files = limit_for_no_token(data["files"] || [], MAX_COMPARE_FILES)
        filtered_files = section_filter_files(files)
        logger.info("#{cid_tag}#{styled_tag('compare')} #{owner}/#{repo} #{previous_tag}...#{current_tag} commits=#{commits.size} files_raw=#{files.size} files_filtered=#{filtered_files.size} section=#{@section_key || 'general'}")

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
        WebTechFeeder::Github::ReferenceExtractor.extract(
          text,
          owner: owner,
          repo: repo,
          limit: (github_token_present? ? nil : MAX_LINKED_REFERENCES)
        )
      end

      def fetch_linked_references(owner, repo, numbers)
        return nil if numbers.empty?
        logger.info("#{cid_tag}#{styled_tag('linked-refs')} #{owner}/#{repo} resolving=#{numbers.size}")

        blocks = []

        numbers.each do |number|
          issue = fetch_issue(owner, repo, number)
          next unless issue

          comments = fetch_issue_comments(owner, repo, number)
          blocks << format_issue_block(issue, comments)
        end

        return nil if blocks.empty?
        logger.info("#{cid_tag}#{styled_tag('linked-refs')} #{owner}/#{repo} resolved=#{blocks.size}")

        "Linked PR/Issue references:\n#{blocks.join("\n\n")}"
      end

      def fetch_issue(owner, repo, number)
        github_client.fetch_issue_meta(
          owner,
          repo,
          number,
          not_found_log: "[linked-refs] #{owner}/#{repo}##{number} not found (404), skip reference",
          error_log: "Failed to fetch linked issue #{owner}/#{repo}##{number}"
        )
      end

      def fetch_issue_comments(owner, repo, number)
        github_client.fetch_issue_comments(
          owner,
          repo,
          number,
          max_no_token: MAX_COMMENTS_PER_REFERENCE,
          pagination_log_tag: "linked-comments #{owner}/#{repo}##{number}",
          error_log: "Failed to fetch linked issue comments #{owner}/#{repo}##{number}",
          empty_on_error: []
        )
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

      def limit_for_no_token(arr, limit)
        return arr if github_token_present?

        arr.first(limit)
      end

      def section_filter_files(files)
        patterns = config.section_file_filter_patterns(@section_key)
        SectionFileFilter.apply(files, patterns)
      end

      def styled_tag(name)
        Utils::LogTagStyler.style(name)
      end

    end
  end
end
