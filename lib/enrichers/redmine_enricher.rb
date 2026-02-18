# frozen_string_literal: true

require "faraday"
require "json"
require_relative "../utils/text_truncator"

module WebTechFeeder
  module Enrichers
    # Fetches full issue + journals from Redmine REST API.
    # Used to enrich RSS entries linking to bugs.ruby-lang.org/issues/{id}.
    class RedmineEnricher
      REDMINE_ISSUE_URL = %r{\Ahttps?://bugs\.ruby-lang\.org/issues/(\d+)(?:\?\S*)?\z}i

      class << self
        def match?(url)
          url.to_s.match?(REDMINE_ISSUE_URL)
        end

        def enrich(url, logger: nil)
          return nil unless match?(url)

          id = url.match(REDMINE_ISSUE_URL)[1]
          fetch_issue_with_journals(id, logger)
        rescue StandardError => e
          logger&.warn("Redmine enrich failed for #{url}: #{e.message}")
          nil
        end

        private

        def fetch_issue_with_journals(issue_id, logger)
          base = "https://bugs.ruby-lang.org"
          conn = Faraday.new(url: base) do |f|
            f.request :retry, max: 2, interval: 1, backoff_factor: 2,
                              exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
            f.adapter Faraday.default_adapter
            f.options.timeout = 15
            f.options.open_timeout = 5
            f.headers["User-Agent"] = "WebTechFeeder/1.0"
          end

          resp = conn.get("/issues/#{issue_id}.json", include: "journals")
          return nil unless resp.status == 200

          data = JSON.parse(resp.body)
          format_issue_and_journals(data, logger)
        rescue JSON::ParserError, Faraday::Error => e
          logger&.warn("Redmine API error for issue #{issue_id}: #{e.message}")
          nil
        end

        def format_issue_and_journals(data, logger)
          issue = data["issue"] || data
          journals = data["journals"] || issue["journals"] || []

          parts = []
          # Issue description
          desc = issue["description"]&.strip
          parts << "Description:\n#{desc}" if desc && !desc.empty?

          # Journals (comments/discussion)
          comment_entries = journals.select { |j| j["notes"].to_s.strip != "" }
          if comment_entries.any?
            parts << "Discussion (#{comment_entries.size} entries):"
            comment_entries.each do |j|
              user = j.dig("user", "name") || "Unknown"
              created = j["created_on"]
              notes = j["notes"].to_s.strip.gsub(/\r\n|\r/, "\n")
              parts << "[#{created}] #{user}:\n#{notes}"
            end
          end

          return nil if parts.empty?

          result = parts.join("\n\n")
          truncate_for_prompt(result, max_length: 4000)
        end

        def truncate_for_prompt(text, max_length: 4000)
          Utils::TextTruncator.truncate(text, max_length: max_length)
        end
      end
    end
  end
end
