# frozen_string_literal: true

require_relative "../section_file_filter"
require_relative "../utils/log_tag_styler"

module WebTechFeeder
  module Github
    # Formats PR metadata and file changes into a consistent compare block.
    module PrCompareFormatter
      module_function

      def format(pr:, files:, section_key:, section_patterns:, logger: nil, log_prefix: "", log_tag: "pr-compare")
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

        filtered_files = WebTechFeeder::SectionFileFilter.apply(files, section_patterns || [])
        styled_tag = Utils::LogTagStyler.style(log_tag)
        logger&.info(
          "#{log_prefix}#{styled_tag} #{pr.dig('base', 'repo', 'full_name') || 'repo'}##{num} " \
          "files_raw=#{files.size} files_filtered=#{filtered_files.size} section=#{section_key || 'general'}"
        )

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
    end
  end
end
