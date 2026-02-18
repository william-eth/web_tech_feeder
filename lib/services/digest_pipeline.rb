# frozen_string_literal: true

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

        formatter.phase("STEP 1/3", "Collect data from all sources")
        raw_data = CategoryCollector.new(config).collect_all
        total = raw_data.values.sum(&:size)
        logger.info("[cid=#{config.run_id}] Collected #{total} items total across all categories")

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

        formatter.phase("STEP 3/3", config.dry_run? ? "Render dry-run preview" : "Send digest email")
        if config.dry_run?
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
    end
  end
end
