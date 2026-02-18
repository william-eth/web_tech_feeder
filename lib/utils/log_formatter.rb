# frozen_string_literal: true

module WebTechFeeder
  module Utils
    # Formats pipeline-level logs for consistent, human-friendly output.
    class LogFormatter
      def initialize(logger:, run_id:, project_name:, project_version:)
        @logger = logger
        @run_id = run_id.to_s
        @project_name = project_name
        @project_version = project_version
      end

      def banner(tag, title)
        return unless @logger

        cid = @run_id.strip
        color = banner_color(tag)
        inner_width = 58
        top = ".oO" + ("=" * inner_width) + "Oo."
        mid = "|" + ("-" * (inner_width + 2)) + "|"
        details = banner_details(tag)

        @logger.info("[cid=#{cid}] [banner] #{tag}") unless cid.empty?
        @logger.info(ansi(color, top))
        @logger.info(ansi(color, mid))
        banner_art(tag).each do |row|
          @logger.info(ansi(color, "| #{row.ljust(inner_width)} |"))
        end
        @logger.info(ansi(color, "| #{''.ljust(inner_width)} |"))
        details.each do |row|
          @logger.info(ansi(color, "| #{row.ljust(inner_width)} |"))
        end
        @logger.info(ansi(color, "| #{''.ljust(inner_width)} |")) unless details.empty?
        @logger.info(ansi(color, "| #{title.ljust(inner_width)} |"))
        @logger.info(ansi(color, top))
      end

      def phase(phase, detail)
        @logger.info(ansi(96, "[##] #{phase.ljust(8)} >> #{detail}"))
      end

      def runtime_config(config)
        ai_model = config.ai_provider == "openai" ? config.ai_model : config.gemini_model
        @logger.info(ansi(93, "Runtime config"))
        runtime_config_line("dry_run", config.dry_run?)
        runtime_config_line("lookback_days", config.lookback_days)
        runtime_config_line("deep_pr_crawl", config.deep_pr_crawl?)
        runtime_config_line("collect_parallel", config.collect_parallel?)
        runtime_config_line("max_collect_threads", config.max_collect_threads)
        runtime_config_line("max_repo_threads", config.max_repo_threads)
        runtime_config_line("digest_min_importance", config.digest_min_importance)
        runtime_config_line("ai_provider", config.ai_provider)
        runtime_config_line("ai_model", ai_model)
        runtime_config_line("github_token_present", !config.github_token.to_s.strip.empty?)
        runtime_config_line("ruby", RUBY_VERSION)
        runtime_config_line("yjit_enabled", yjit_enabled?)
      end

      def run_timing(status:, started_at:, finished_at:, elapsed_seconds:)
        @logger.info(ansi(93, "Run timing"))
        @logger.info("  #{ansi(96, 'status')}=#{ansi(status == 'success' ? 92 : 91, status)}")
        @logger.info("  #{ansi(96, 'started_at')}=#{ansi(97, started_at.iso8601)}")
        @logger.info("  #{ansi(96, 'finished_at')}=#{ansi(97, finished_at.iso8601)}")
        @logger.info("  #{ansi(96, 'duration')}=#{ansi(97, human_duration_label(elapsed_seconds))} (#{format('%.2f', elapsed_seconds)}s)")
      end

      def dry_run_preview(path)
        @logger.info(ansi(92, "Dry-run mode: HTML preview saved to #{path}"))
        @logger.info(ansi(94, "Open it in your browser: open #{path}"))
      end

      private

      def runtime_config_line(key, value)
        key_colored = ansi(96, key.to_s)
        value_color = value == true ? 92 : 97
        value_colored = ansi(value_color, value.to_s)
        @logger.info("  #{key_colored}=#{value_colored}")
      end

      def ansi(color_code, text)
        "\e[#{color_code}m#{text}\e[0m"
      end

      def yjit_enabled?
        return false unless defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enabled?)

        RubyVM::YJIT.enabled?
      end

      def human_duration_label(total_seconds)
        seconds = total_seconds.to_i
        h = seconds / 3600
        m = (seconds % 3600) / 60
        s = seconds % 60
        return "#{h} hr #{m} mins #{s} secs" if h.positive?

        "#{m} mins #{s} secs"
      end

      def banner_color(tag)
        case tag.to_s.upcase
        when "START" then 92
        when "DONE" then 94
        when "NO DATA" then 93
        when "FAILED" then 91
        else 97
        end
      end

      def banner_details(tag)
        return [] unless tag.to_s.upcase == "START"

        [
          "Project : #{@project_name}",
          "Version : #{@project_version}"
        ]
      end

      def banner_art(tag)
        case tag.to_s.upcase
        when "START"
          [
            " __        __   _     _____         _      ",
            " \\ \\      / /__| |__ |_   _|__  ___| |__   ",
            "  \\ \\ /\\ / / _ \\ '_ \\  | |/ _ \\/ __| '_ \\  ",
            "   \\ V  V /  __/ |_) | | |  __/ (__| | | | ",
            "    \\_/\\_/ \\___|_.__/  |_|\\___|\\___|_| |_| ",
            "              W E B   T E C H   F E E D E R"
          ]
        when "DONE"
          [
            " _____   ____   _   _   _____ ",
            "|  __ \\ / __ \\ | \\ | | | ____|",
            "| |  | | |  | ||  \\| | |  _|  ",
            "| |__| | |__| || |\\  | | |___ ",
            "|_____/ \\____/ |_| \\_| |_____|"
          ]
        when "FAILED"
          [
            " _____   _    ___   _      _____   ____  ",
            "|  ___| / \\  |_ _| | |    | ____| |  _ \\ ",
            "| |_   / _ \\  | |  | |    |  _|   | | | |",
            "|  _| / ___ \\ | |  | |___ | |___  | |_| |",
            "|_|  /_/   \\_\\___| |_____||_____| |____/ "
          ]
        when "NO DATA"
          [
            " _   _   ___      ____     _      _____      _      ",
            "| \\ | | / _ \\    |  _ \\   / \\    |_   _|    / \\     ",
            "|  \\| || | | |   | | | | / _ \\     | |     / _ \\    ",
            "| |\\  || |_| |   | |_| |/ ___ \\    | |    / ___ \\   ",
            "|_| \\_| \\___/    |____//_/   \\_\\   |_|   /_/   \\_\\  "
          ]
        else
          [tag.to_s]
        end
      end
    end
  end
end
