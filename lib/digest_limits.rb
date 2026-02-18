# frozen_string_literal: true

module WebTechFeeder
  module DigestLimits
    MAX_ITEMS_PER_CATEGORY = 10
    MAX_RELEASES_PER_CATEGORY = 3
    MAX_TOTAL_PER_CATEGORY = 7 # releases + others combined
    MIN_ISSUE_BLOG_PER_CATEGORY = 2
    ISSUE_BLOG_TYPES = %w[issue other].freeze
  end
end
