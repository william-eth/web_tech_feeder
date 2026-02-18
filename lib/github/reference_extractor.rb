# frozen_string_literal: true

module WebTechFeeder
  module Github
    # Extracts GitHub issue/PR reference numbers from free text with strict context.
    module ReferenceExtractor
      module_function

      def extract(text, owner:, repo:, limit: nil)
        raw = text.to_s
        return [] if raw.strip.empty?

        refs = []
        refs.concat(extract_from_urls(raw, owner, repo))
        refs.concat(extract_from_context(raw))
        refs.concat(extract_from_bracket_refs(raw))
        refs.concat(raw.scan(/\bGH-(\d{1,7})\b/i).flatten.map(&:to_i))

        # Ignore common non-GitHub tracker formats.
        non_github_refs = raw.scan(/\b(?:ticket|trac|jira|redmine)\s+#(\d{1,7})\b/i).flatten.map(&:to_i)
        non_github_refs.concat(
          raw.scan(/\b(?:ticket|trac|jira|redmine)\s*(?:issue\s*)?\[\s*#?(\d{1,7})\s*\]/i).flatten.map(&:to_i)
        )
        numbers = refs.uniq - non_github_refs
        return numbers if limit.nil?

        numbers.first(limit)
      end

      def extract_from_urls(text, owner, repo)
        escaped_owner = Regexp.escape(owner.to_s)
        escaped_repo = Regexp.escape(repo.to_s)
        pattern = %r{https?://github\.com/#{escaped_owner}/#{escaped_repo}/(?:issues|pull)/(\d+)}i
        text.to_s.scan(pattern).flatten.map(&:to_i)
      end

      def extract_from_context(text)
        pattern = /
          \b(?:pr|pull\ request|pull|issue|fix(?:es|ed)?|close(?:s|d)?|resolve(?:s|d)?|ref(?:er(?:ence|ences|enced)?)?)\b
          [^#\n]{0,50}
          \#(\d{1,7})\b
        /ix
        text.to_s.scan(pattern).flatten.map(&:to_i)
      end

      # Common changelog style references: [#1234], [PR #1234].
      def extract_from_bracket_refs(text)
        raw = text.to_s
        refs = []
        refs.concat(raw.scan(/\[\s*#(\d{1,7})\s*\]/i).flatten.map(&:to_i))
        refs.concat(raw.scan(/\[\s*(?:pr|pull)\s*#(\d{1,7})\s*\]/i).flatten.map(&:to_i))
        refs
      end
    end
  end
end
