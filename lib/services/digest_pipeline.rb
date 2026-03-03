# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "../config"
require_relative "../digest_limits"
require_relative "../processor/gemini_processor"
require_relative "../processor/openai_processor"
require_relative "../notifier/smtp_notifier"
require_relative "../utils/log_formatter"
require_relative "category_collector"
require_relative "digest_filter"

module WebTechFeeder
  module Services
    # Main orchestrator for the digest pipeline.
    class DigestPipeline
      PROJECT_NAME = "Web Tech Feeder"

      def run
        started_at = Time.now
        status = "success"
        config = Config.new
        config.run_id = "run-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}"
        logger = config.logger
        formatter = build_log_formatter(config)

        formatter.banner("START", "(^_^)/ Weekly Digest Boot")
        logger.info("[cid=#{config.run_id}] Looking back #{config.lookback_days} days in TPE since #{config.cutoff_time}")
        formatter.runtime_config(config)

        formatter.phase("STEP 1/3", config.dry_run_from_cache? ? "Load cached collection" : "Collect data from all sources")
        raw_data = if config.dry_run_from_cache?
          load_collection_cache(config)
        else
          CategoryCollector.new(config).collect_all.tap do |data|
            save_collection_cache(config, data) if config.dry_run?
          end
        end
        total = raw_data.values.sum(&:size)
        logger.info("[cid=#{config.run_id}] #{config.dry_run_from_cache? ? 'Loaded' : 'Collected'} #{total} items total across all categories")

        if total.zero?
          status = "no_data"
          formatter.banner("NO DATA", "(._.) Nothing new in this window")
          logger.warn("No items found in the past #{config.lookback_days} days. Skipping digest.")
          return
        end

        formatter.phase("STEP 2/3", "Process digest with AI")
        processor = build_processor(config)
        digest_data = processor.process(raw_data)
        digest_data = DigestFilter.new(config).apply(digest_data)

        formatter.phase("STEP 3/3", (config.dry_run? || config.dry_run_from_cache?) ? "Render dry-run preview" : "Send digest email")
        config.project_version = project_version
        if config.dry_run? || config.dry_run_from_cache?
          save_preview(config, digest_data, formatter)
        else
          Notifier::SmtpNotifier.new(config).send_digest(digest_data)
        end

        formatter.banner("DONE", "(>_<)b Digest generation complete")
      rescue StandardError => e
        status = "failed"
        build_log_formatter(config)&.banner("FAILED", "(T_T) Pipeline aborted")
        config&.logger&.error("Fatal error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
        raise
      ensure
        if config&.logger
          finished_at = Time.now
          elapsed_seconds = finished_at - started_at
          build_log_formatter(config).run_timing(
            status: status,
            started_at: started_at,
            finished_at: finished_at,
            elapsed_seconds: elapsed_seconds
          )
        end
      end

      private

      def build_processor(config)
        case config.ai_provider
        when "openai"
          Processor::OpenaiProcessor.new(config)
        else
          Processor::GeminiProcessor.new(config)
        end
      end

      def save_preview(config, digest_data, formatter)
        require "fileutils"
        require "erb"
        require_relative "../notifier/smtp_notifier"

        renderer = Notifier::TemplateRenderer.new(digest_data, config)
        template = File.read(Notifier::SmtpNotifier::TEMPLATE_PATH)
        html = ERB.new(template, trim_mode: "-").result(renderer.get_binding)

        preview_dir = File.expand_path("../../tmp", __dir__)
        FileUtils.mkdir_p(preview_dir)
        preview_path = File.join(preview_dir, "digest_preview.html")
        File.write(preview_path, html)

        formatter.dry_run_preview(preview_path)
      end

      def project_version
        @project_version ||= begin
          v = ENV["PROJECT_VERSION"].to_s.strip
          return v if v != ""

          changelog = File.expand_path("../../CHANGELOG.md", __dir__)
          first_version_line = File.foreach(changelog).find { |line| line.start_with?("## [") && !line.include?("Unreleased") }
          first_version_line&.match(/\[(.+?)\]/)&.captures&.first || "unknown"
        rescue StandardError
          "unknown"
        end
      end

      def build_log_formatter(config)
        return nil unless config&.logger

        Utils::LogFormatter.new(
          logger: config.logger,
          run_id: config.run_id,
          project_name: PROJECT_NAME,
          project_version: project_version
        )
      end

      def save_collection_cache(config, raw_data)
        path = config.collection_cache_path
        FileUtils.mkdir_p(File.dirname(path))
        serialized = serialize_raw_data(raw_data)
        File.write(path, JSON.pretty_generate(serialized))
        config.logger.info("[cid=#{config.run_id}] Saved collection cache to #{path}")
      end

      def load_collection_cache(config)
        path = config.collection_cache_path
        raise "Collection cache not found: #{path}. Run with DRY_RUN=true first to generate it." unless File.file?(path)

        config.logger.info("[cid=#{config.run_id}] Loading collection cache from #{File.expand_path(path)}")
        serialized = JSON.parse(File.read(path))
        deserialize_raw_data(serialized)
      end

      def serialize_raw_data(raw_data)
        raw_data.transform_values do |items|
          items.map do |item|
            h = item.respond_to?(:to_h) ? item.to_h : item
            h.transform_values { |v| v.is_a?(Time) ? v.utc.iso8601 : v }
          end
        end
      end

      def deserialize_raw_data(serialized)
        item_klass = Collectors::BaseCollector::Item
        serialized.transform_keys(&:to_sym).transform_values do |items|
          items.map do |h|
            hash = h.transform_keys(&:to_sym)
            published_at = hash[:published_at]
            published_at = Time.parse(published_at) if published_at.is_a?(String)
            item_klass.new(
              title: hash[:title],
              url: hash[:url],
              published_at: published_at,
              body: hash[:body],
              source: hash[:source]
            )
          end
        end
      end
    end
  end
end
