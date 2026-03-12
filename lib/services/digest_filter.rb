# frozen_string_literal: true

require_relative "../digest_limits"
require_relative "../utils/item_type_inferrer"
require_relative "../utils/security_signal"

module WebTechFeeder
  module Services
    # Applies digest post-processing rules for importance and section split.
    class DigestFilter
      def initialize(config)
        @config = config
      end

      def apply(digest_data)
        split_releases_from_others(filter_by_importance(digest_data))
      end

      private

      def split_releases_from_others(digest_data)
        digest_data.transform_values do |section|
          next section unless section.is_a?(Hash) && section[:items]

          items = section[:items].reject { |i| advisory_without_security_material?(i) }
          security_from_items = items.select { |i| security_item?(i) }

          # Layer 3 safety net: when processor failed to create advisories,
          # synthesize them from items that carry explicit CVE/GHSA IDs.
          injected_security = security_from_items.empty? ? inject_advisory_from_cve_items(items) : []
          security = security_from_items + injected_security

          releases = items.select { |i| item_type(i) == "release" }
          releases = deduplicate_releases(releases)
          others = items.reject { |i| item_type(i) == "release" || security_from_items.include?(i) }

          all_major = items.all? { |i| %w[critical high].include?((i[:importance] || "").downcase) }
          total_cap = all_major ? DigestLimits::MAX_ITEMS_PER_CATEGORY : DigestLimits::MAX_TOTAL_PER_CATEGORY

          release_items = releases.first(DigestLimits::MAX_RELEASES_PER_CATEGORY)
          security_items = security.first(DigestLimits::MAX_SECURITY_PER_CATEGORY)
          remaining_slots = total_cap - release_items.size - security_items.size
          other_items = others.first([remaining_slots, 0].max)

          section.merge(release_items: release_items, security_items: security_items, other_items: other_items)
        end
      end

      def security_item?(item)
        level = (item[:importance] || "").downcase
        kind = item_type(item)

        if kind == "advisory"
          return DigestLimits::SECURITY_MIN_IMPORTANCE.include?(level) && advisory_security_material?(item)
        end

        # Keep release notes in the release subsection. Security block focuses
        # on dedicated security advisories / major security incidents.
        return false if kind == "release"
        return false unless %w[critical high].include?(level)

        security_signal?(item)
      end

      def advisory_without_security_material?(item)
        item_type(item) == "advisory" && !advisory_security_material?(item)
      end

      def advisory_security_material?(item)
        explicit_security_id?(item) || security_signal?(item) || advisory_source?(item)
      end

      def explicit_security_id?(item)
        text = [
          item[:title],
          item[:summary],
          item[:source_name],
          item[:source_url]
        ].join(" ")

        Utils::SecuritySignal.explicit_security_id_signal?(text)
      end

      def advisory_source?(item)
        item[:source_name].to_s.downcase.match?(/advisory|security announcements|official cve feed/)
      end

      def security_signal?(item)
        combined_text = [
          item[:title],
          item[:framework_or_package],
          item[:source_name],
          item[:source_url]
        ].join(" ").downcase

        explicit_vuln_id = Utils::SecuritySignal.explicit_security_id_signal?(combined_text)
        vuln_keyword = Utils::SecuritySignal.vulnerability_keyword_signal?(combined_text) ||
                       combined_text.match?(/\b(sqli|auth(?:entication)? bypass|privilege escalation)\b/)
        strong_security_phrase = Utils::SecuritySignal.strong_security_phrase_signal?(combined_text)
        security_advisory_source = Utils::SecuritySignal.advisory_source_signal?(item[:source_name])

        explicit_vuln_id || vuln_keyword || strong_security_phrase || security_advisory_source
      end

      # Create advisory clones from items that mention CVE/GHSA when the
      # processor and AI both failed to produce dedicated advisory entries.
      # The cloned items get item_type "advisory" so they render in the
      # security subsection while the originals stay in their own subsection.
      MAX_INJECTED_ADVISORIES = 2

      def inject_advisory_from_cve_items(items)
        cve_items = items.select { |i| explicit_security_id?(i) }
        return [] if cve_items.empty?

        cve_items.first(MAX_INJECTED_ADVISORIES).map do |src|
          src.merge(item_type: "advisory")
        end
      end

      def deduplicate_releases(releases)
        seen = {}
        releases.each do |item|
          key = normalize_release_key(item)
          existing = seen[key]
          if existing.nil? || importance_rank(item[:importance]) > importance_rank(existing[:importance])
            seen[key] = item
          end
        end
        seen.values
      end

      def normalize_release_key(item)
        title = item[:title].to_s.downcase
        version = title[/v?\d[\d._-]+/]
        pkg = (item[:framework_or_package] || "").downcase.strip
        pkg = title.split(/\s+/).first.to_s.downcase if pkg.empty?
        return item[:source_url].to_s if version.to_s.empty?

        "#{pkg}:#{version}"
      end

      def filter_by_importance(digest_data)
        min = @config.digest_min_importance
        digest_data.transform_values do |section|
          next section unless section.is_a?(Hash) && section[:items]

          items = section[:items].map { |i| ensure_item_type(i) }

          # Advisory items bypass the general importance filter —
          # they have a dedicated importance check in security_item?.
          advisories = items.select { |i| item_type(i) == "advisory" }
          non_advisories = items.reject { |i| item_type(i) == "advisory" }

          by_importance = non_advisories.select do |i|
            importance_rank(i[:importance] || "medium") >= importance_rank(min)
          end
          issue_blog = non_advisories.select { |i| DigestLimits::ISSUE_BLOG_TYPES.include?(item_type(i)) }
          already_has = by_importance.count { |i| DigestLimits::ISSUE_BLOG_TYPES.include?(item_type(i)) }
          reserve_count = [DigestLimits::MIN_ISSUE_BLOG_PER_CATEGORY - already_has, 0].max

          reserve = if reserve_count.positive?
                      issue_blog
                        .reject { |i| by_importance.any? { |a| a[:source_url] == i[:source_url] } }
                        .sort_by { |i| -importance_rank(i[:importance] || "medium") }
                        .first(reserve_count)
                    else
                      []
                    end

          combined = (advisories + by_importance + reserve).uniq { |i| i[:source_url] }
          sorted = combined.sort_by { |i| -importance_rank(i[:importance] || "medium") }
          section.merge(items: sorted.first(DigestLimits::MAX_ITEMS_PER_CATEGORY))
        end
      end

      def ensure_item_type(item)
        return item unless item[:item_type].to_s.strip.empty?

        item[:item_type] = Utils::ItemTypeInferrer.infer(item)
        item
      end

      def item_type(item)
        (item[:item_type] || "").downcase
      end

      def importance_rank(level)
        { "critical" => 4, "high" => 3, "medium" => 2, "low" => 1 }[level.to_s.downcase] || 2
      end
    end
  end
end
