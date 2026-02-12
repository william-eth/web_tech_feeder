# frozen_string_literal: true

require_relative "config"
require_relative "collectors/github_release_collector"
require_relative "collectors/github_issue_collector"
require_relative "collectors/rss_collector"
require_relative "collectors/rubygems_collector"
require_relative "collectors/github_advisory_collector"
require_relative "processor/gemini_processor"
require_relative "processor/openai_processor"
require_relative "notifier/smtp_notifier"

# Main orchestrator for the Web Tech Feeder pipeline.
# Coordinates data collection, AI summarization, and email delivery.
module WebTechFeeder
  module DigestLimits
    MAX_ITEMS_PER_CATEGORY = 5
    MAX_RELEASES_PER_CATEGORY = 3
    MIN_ISSUE_BLOG_PER_CATEGORY = 2
    ISSUE_BLOG_TYPES = %w[issue other].freeze
  end

  class << self
    def run
      config = Config.new
      logger = config.logger

      logger.info("=== Web Tech Feeder - Starting weekly digest generation ===")
      logger.info("Looking back #{config.lookback_days} days from #{Time.now}")

      # Step 1: Collect raw data from all sources
      raw_data = collect_all(config)
      total = raw_data.values.sum(&:size)
      logger.info("Collected #{total} items total across all categories")

      if total.zero?
        logger.warn("No items found in the past #{config.lookback_days} days. Skipping digest.")
        return
      end

      # Step 2: Process with AI
      processor = build_processor(config)
      digest_data = processor.process(raw_data)

      # Step 2.5: Filter to only critical + high importance (keep digest concise)
      digest_data = filter_by_importance(digest_data, config)
      # Step 2.6: Split each section into version_releases (max 3) and other_items
      digest_data = split_releases_from_others(digest_data)

      # Step 3: Send email or save preview
      if config.dry_run?
        save_preview(config, digest_data)
      else
        notifier = Notifier::SmtpNotifier.new(config)
        notifier.send_digest(digest_data)
      end

      logger.info("=== Web Tech Feeder - Digest generation complete ===")
    rescue StandardError => e
      config&.logger&.error("Fatal error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      raise
    end

    private

    def split_releases_from_others(digest_data)
      digest_data.transform_values do |section|
        next section unless section.is_a?(Hash) && section[:items]

        items = section[:items]
        releases = items.select { |i| item_type(i) == "release" }
        others = items.reject { |i| item_type(i) == "release" }

        section.merge(
          release_items: releases.first(DigestLimits::MAX_RELEASES_PER_CATEGORY),
          other_items: others.first(DigestLimits::MAX_ITEMS_PER_CATEGORY)
        )
      end
    end

    def filter_by_importance(digest_data, config)
      min = config.digest_min_importance

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

      item[:item_type] = infer_item_type(item)
      item
    end

    def infer_item_type(item)
      title = (item[:title] || "").downcase
      source = (item[:source_name] || "").downcase
      if title.include?("released") || title.include?("release") || source.include?("/releases/")
        "release"
      elsif source.include?("advisory") || title.include?("cve") || title.include?("security")
        "advisory"
      elsif source.include?("issue") || source.include?("pr")
        "issue"
      else
        "other"
      end
    end

    def item_type(item)
      (item[:item_type] || "").downcase
    end

    def importance_rank(level)
      { "critical" => 4, "high" => 3, "medium" => 2, "low" => 1 }[level.to_s.downcase] || 2
    end

    def build_processor(config)
      case config.ai_provider
      when "openai"
        Processor::OpenaiProcessor.new(config)
      else
        Processor::GeminiProcessor.new(config)
      end
    end

    # In dry-run mode, render the HTML and save to tmp/ for browser preview
    def save_preview(config, digest_data)
      require "fileutils"
      require "erb"
      require_relative "notifier/smtp_notifier"

      renderer = Notifier::TemplateRenderer.new(digest_data, config)
      template = File.read(Notifier::SmtpNotifier::TEMPLATE_PATH)
      html = ERB.new(template, trim_mode: "-").result(renderer.get_binding)

      preview_dir = File.expand_path("../tmp", __dir__)
      FileUtils.mkdir_p(preview_dir)
      preview_path = File.join(preview_dir, "digest_preview.html")
      File.write(preview_path, html)

      config.logger.info("Dry-run mode: HTML preview saved to #{preview_path}")
      config.logger.info("Open it in your browser: open #{preview_path}")
    end

    def collect_all(config)
      sources = config.sources

      {
        frontend: collect_category(config, sources[:frontend]),
        backend: collect_category(config, sources[:backend]),
        devops: collect_category(config, sources[:devops])
      }
    end

    # Unified category collector - handles all source types
    def collect_category(config, source_config)
      items = []
      return items unless source_config

      # GitHub Releases
      if source_config[:github_releases]&.any?
        collector = Collectors::GithubReleaseCollector.new(config, repos: source_config[:github_releases])
        items.concat(collector.collect)
      end

      # GitHub Issues & PRs (community discussions)
      if source_config[:github_issues]&.any?
        collector = Collectors::GithubIssueCollector.new(config, repos: source_config[:github_issues])
        items.concat(collector.collect)
      end

      # RSS Feeds
      if source_config[:rss_feeds]&.any?
        collector = Collectors::RssCollector.new(config, feeds: source_config[:rss_feeds])
        items.concat(collector.collect)
      end

      # RubyGems (backend-specific)
      if source_config[:rubygems]&.any?
        collector = Collectors::RubygemsCollector.new(config, gem_names: source_config[:rubygems])
        items.concat(collector.collect)
      end

      # GitHub Security Advisories
      if source_config[:github_advisories]
        adv_config = source_config[:github_advisories]
        collector = Collectors::GithubAdvisoryCollector.new(
          config,
          ecosystem: adv_config[:ecosystem],
          packages: adv_config[:packages]
        )
        items.concat(collector.collect)
      end

      items
    end
  end
end
