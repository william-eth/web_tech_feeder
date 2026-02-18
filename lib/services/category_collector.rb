# frozen_string_literal: true

require_relative "../collectors/github_release_collector"
require_relative "../collectors/github_issue_collector"
require_relative "../collectors/rss_collector"
require_relative "../collectors/rubygems_collector"
require_relative "../collectors/github_advisory_collector"
require_relative "../utils/parallel_executor"

module WebTechFeeder
  module Services
    # Orchestrates category/source collection and keeps output ordering stable.
    class CategoryCollector
      def initialize(config)
        @config = config
        @logger = config.logger
      end

      def collect_all
        sources = @config.sources
        {
          frontend: collect_category(:frontend, sources[:frontend]),
          backend: collect_category(:backend, sources[:backend]),
          devops: collect_category(:devops, sources[:devops])
        }
      end

      private

      def collect_category(category, source_config)
        return [] unless source_config

        source_jobs = build_source_jobs(category, source_config)
        results = run_source_jobs(category, source_jobs)
        items = results.flatten.compact
        deduped = deduplicate_release_versions(items)
        stable_sort_items(deduped)
      end

      def build_source_jobs(category, source_config)
        jobs = []
        jobs << github_releases_job(category, source_config[:github_releases]) if source_config[:github_releases]&.any?
        jobs << github_issues_job(category, source_config[:github_issues]) if source_config[:github_issues]&.any?
        jobs << rss_feeds_job(category, source_config[:rss_feeds]) if source_config[:rss_feeds]&.any?
        jobs << rubygems_job(source_config[:rubygems]) if source_config[:rubygems]&.any?
        jobs << github_advisories_job(source_config[:github_advisories]) if source_config[:github_advisories]
        jobs
      end

      def github_releases_job(category, repos)
        {
          name: "github_releases",
          call: lambda {
            collector = Collectors::GithubReleaseCollector.new(
              @config,
              repos: repos,
              section_key: category
            )
            collector.collect
          }
        }
      end

      def github_issues_job(category, repos)
        {
          name: "github_issues",
          call: lambda {
            collector = Collectors::GithubIssueCollector.new(
              @config,
              repos: repos,
              section_key: category
            )
            collector.collect
          }
        }
      end

      def rss_feeds_job(category, feeds)
        {
          name: "rss_feeds",
          call: lambda {
            collector = Collectors::RssCollector.new(
              @config,
              feeds: feeds,
              section_key: category
            )
            collector.collect
          }
        }
      end

      def rubygems_job(gem_names)
        {
          name: "rubygems",
          call: lambda {
            collector = Collectors::RubygemsCollector.new(@config, gem_names: gem_names)
            collector.collect
          }
        }
      end

      def github_advisories_job(adv_config)
        {
          name: "github_advisories",
          call: lambda {
            collector = Collectors::GithubAdvisoryCollector.new(
              @config,
              ecosystem: adv_config[:ecosystem],
              packages: adv_config[:packages]
            )
            collector.collect
          }
        }
      end

      def run_source_jobs(category, source_jobs)
        return [] if source_jobs.empty?

        parallel_enabled = @config.collect_parallel? && source_jobs.size > 1 && @config.max_collect_threads > 1
        worker_count = [@config.max_collect_threads, source_jobs.size].min

        if parallel_enabled
          @logger.info("[collect-parallel] category=#{category} jobs=#{source_jobs.size} workers=#{worker_count}")
        end

        Utils::ParallelExecutor.map(
          source_jobs,
          max_threads: worker_count,
          parallel: parallel_enabled,
          logger: @logger
        ) do |job|
          run_source_job(category, job)
        end
      end

      def run_source_job(category, job)
        @logger.info("[collect-source] category=#{category} start=#{job[:name]}")
        result = job[:call].call || []
        @logger.info("[collect-source] category=#{category} done=#{job[:name]} items=#{result.size}")
        result
      rescue StandardError => e
        @logger.warn("[collect-source] category=#{category} failed=#{job[:name]} error=#{e.class}: #{e.message}")
        []
      end

      def stable_sort_items(items)
        items.sort_by do |item|
          published_at = item.respond_to?(:published_at) ? item.published_at : item[:published_at]
          title = item.respond_to?(:title) ? item.title.to_s : item[:title].to_s
          source = item.respond_to?(:source) ? item.source.to_s : item[:source].to_s
          url = item.respond_to?(:url) ? item.url.to_s : item[:url].to_s
          [-(published_at&.to_i || 0), title, source, url]
        end
      end

      def deduplicate_release_versions(items)
        grouped = {}
        items.each do |item|
          key = release_dedupe_key(item)
          if key.nil?
            grouped[[:passthrough, grouped.size]] = [item]
          else
            grouped[key] ||= []
            grouped[key] << item
          end
        end

        deduped = grouped.values.map do |bucket|
          next bucket.first if bucket.size == 1

          bucket.max_by { |item| release_item_priority(item) }
        end

        removed = items.size - deduped.size
        @logger.info("[collect-dedupe] removed=#{removed} duplicate release items") if removed.positive?
        deduped
      end

      def release_dedupe_key(item)
        title = item.respond_to?(:title) ? item.title.to_s : item[:title].to_s
        source = item.respond_to?(:source) ? item.source.to_s : item[:source].to_s
        return nil unless source.start_with?("GitHub - ", "RubyGems - ")

        match = title.match(/\A(.+)\s+v?(\d+\.\d+\.\d+[-.\w]*)\s+released\z/i)
        return nil unless match

        package = match[1].to_s.strip.downcase
        version = match[2].to_s.strip.sub(/\Av/i, "").downcase
        [:release, package, version]
      end

      def release_item_priority(item)
        source = item.respond_to?(:source) ? item.source.to_s : item[:source].to_s
        body = item.respond_to?(:body) ? item.body.to_s : item[:body].to_s
        published_at = item.respond_to?(:published_at) ? item.published_at : item[:published_at]

        source_rank = case source
                      when /\AGitHub - / then 3
                      when /\ARubyGems - / then 2
                      else 1
                      end

        # Prefer richer bodies and newer timestamps when source rank ties.
        [source_rank, body.length, published_at&.to_i || 0]
      end
    end
  end
end
