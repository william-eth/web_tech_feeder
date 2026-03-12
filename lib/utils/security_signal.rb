# frozen_string_literal: true

module WebTechFeeder
  module Utils
    # Shared security signal helpers to keep regex rules consistent
    # across processor/filter layers.
    module SecuritySignal
      CVE_ID_REGEX = /\bcve-\d{4}-\d+\b/i
      GHSA_ID_REGEX = /\bghsa-[a-z0-9-]+\b/i
      VULNERABILITY_KEYWORD_REGEX = /\b(vulnerability|vulnerable|buffer overflow|use-after-free|rce|xss|ssrf|csrf|sql injection)\b/i
      STRONG_SECURITY_PHRASE_REGEX = /\bsecurity (?:advisory|announcement|bulletin|cve|fix|patch)\b/i
      ADVISORY_SOURCE_REGEX = /security advisories|security announcements|official cve feed/i

      module_function

      def explicit_security_id_signal?(text)
        s = text.to_s
        return false if s.empty?

        s.match?(CVE_ID_REGEX) || s.match?(GHSA_ID_REGEX)
      end

      def vulnerability_keyword_signal?(text)
        s = text.to_s
        return false if s.empty?

        s.match?(VULNERABILITY_KEYWORD_REGEX)
      end

      def advisory_security_signal?(text)
        explicit_security_id_signal?(text) || vulnerability_keyword_signal?(text)
      end

      def strong_security_phrase_signal?(text)
        s = text.to_s
        return false if s.empty?

        s.match?(STRONG_SECURITY_PHRASE_REGEX)
      end

      def advisory_source_signal?(text)
        s = text.to_s
        return false if s.empty?

        s.match?(ADVISORY_SOURCE_REGEX)
      end
    end
  end
end
