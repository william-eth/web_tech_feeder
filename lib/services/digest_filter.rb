# frozen_string_literal: true

require_relative "../digest_limits"
require_relative "../utils/item_type_inferrer"

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

          items = section[:items]
          releases = items.select { |i| item_type(i) == "release" }
          others = items.reject { |i| item_type(i) == "release" }

          # When all items are major (critical/high), bypass the 7-item cap; show up to 10
          all_major = items.all? { |i| %w[critical high].include?((i[:importance] || "").downcase) }
          total_cap = all_major ? DigestLimits::MAX_ITEMS_PER_CATEGORY : DigestLimits::MAX_TOTAL_PER_CATEGORY

          release_items = releases.first(DigestLimits::MAX_RELEASES_PER_CATEGORY)
          remaining_slots = total_cap - release_items.size
          other_items = others.first([remaining_slots, 0].max)

          section.merge(release_items: release_items, other_items: other_items)
        end
      end

      def filter_by_importance(digest_data)
        min = @config.digest_min_importance
        digest_data.transform_values do |section|
          next section unless section.is_a?(Hash) && section[:items]

          items = section[:items].map { |i| ensure_item_type(i) }
          by_importance = items.select { |i| importance_rank(i[:importance] || "medium") >= importance_rank(min) }
          issue_blog = items.select { |i| DigestLimits::ISSUE_BLOG_TYPES.include?(item_type(i)) }
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

          combined = (by_importance + reserve).uniq { |i| i[:source_url] }
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
