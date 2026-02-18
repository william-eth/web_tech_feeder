# frozen_string_literal: true

require_relative "reference_extractor"
require_relative "pr_compare_formatter"
require_relative "../utils/log_tag_styler"

module WebTechFeeder
  module Github
    # Builds PR compare context for direct PR items and linked PR references.
    module PrContextBuilder
      module_function

      def build(issue:, comments:, owner:, repo:, deep_pr_crawl:, token_present:, max_linked_refs_no_token:,
                fetch_issue_meta:, fetch_pr_meta:, fetch_pr_files:, max_pr_files_no_token:,
                section_key:, section_patterns:, logger:, log_prefix:, pr_compare_tag:, linked_tag:, pr_files_log_tag_prefix:)
        unless deep_pr_crawl
          logger&.info("#{log_prefix}#{Utils::LogTagStyler.style(pr_compare_tag)} #{owner}/#{repo}##{issue['number']} deep PR crawl disabled")
          return nil
        end

        if issue.key?("pull_request")
          logger&.info("#{log_prefix}#{Utils::LogTagStyler.style(pr_compare_tag)} #{owner}/#{repo}##{issue['number']} direct PR compare")
          formatted = format_single_pr(
            number: issue["number"],
            owner: owner,
            repo: repo,
            fetch_pr_meta: fetch_pr_meta,
            fetch_pr_files: fetch_pr_files,
            max_pr_files_no_token: max_pr_files_no_token,
            section_key: section_key,
            section_patterns: section_patterns,
            logger: logger,
            log_prefix: log_prefix,
            pr_compare_tag: pr_compare_tag,
            pr_files_log_tag_prefix: pr_files_log_tag_prefix
          )
          return nil unless formatted

          return "PR Compare:\n#{formatted}"
        end

        ref_text = [issue["body"].to_s, comments.map { |c| c["body"].to_s }.join("\n")].join("\n")
        referenced_numbers = WebTechFeeder::Github::ReferenceExtractor.extract(
          ref_text,
          owner: owner,
          repo: repo,
          limit: (token_present ? nil : max_linked_refs_no_token)
        )
        logger&.info("#{log_prefix}#{Utils::LogTagStyler.style(linked_tag)} #{owner}/#{repo}##{issue['number']} extracted_refs=#{referenced_numbers.size}")
        return nil if referenced_numbers.empty?

        blocks = []
        referenced_numbers.each do |num|
          linked = fetch_issue_meta.call(num)
          next unless linked&.key?("pull_request")

          logger&.info("#{log_prefix}#{Utils::LogTagStyler.style(linked_tag)} #{owner}/#{repo}##{issue['number']} resolving_pr_ref=#{num}")
          formatted = format_single_pr(
            number: num,
            owner: owner,
            repo: repo,
            fetch_pr_meta: fetch_pr_meta,
            fetch_pr_files: fetch_pr_files,
            max_pr_files_no_token: max_pr_files_no_token,
            section_key: section_key,
            section_patterns: section_patterns,
            logger: logger,
            log_prefix: log_prefix,
            pr_compare_tag: pr_compare_tag,
            pr_files_log_tag_prefix: pr_files_log_tag_prefix
          )
          next unless formatted

          blocks << "[Linked PR ##{num}]\n#{formatted}"
        end

        return nil if blocks.empty?

        logger&.info("#{log_prefix}#{Utils::LogTagStyler.style(linked_tag)} #{owner}/#{repo}##{issue['number']} resolved_pr_refs=#{blocks.size}")
        "Linked PR Compare:\n#{blocks.join("\n\n")}"
      end

      def format_single_pr(number:, owner:, repo:, fetch_pr_meta:, fetch_pr_files:, max_pr_files_no_token:,
                           section_key:, section_patterns:, logger:, log_prefix:, pr_compare_tag:, pr_files_log_tag_prefix:)
        pr = fetch_pr_meta.call(number)
        return nil unless pr

        files = fetch_pr_files.call(number, max_pr_files_no_token, "#{pr_files_log_tag_prefix} #{owner}/#{repo}##{number}")
        WebTechFeeder::Github::PrCompareFormatter.format(
          pr: pr,
          files: files || [],
          section_key: section_key,
          section_patterns: section_patterns,
          logger: logger,
          log_prefix: log_prefix,
          log_tag: pr_compare_tag
        )
      end
      private_class_method :format_single_pr
    end
  end
end
