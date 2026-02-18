# frozen_string_literal: true

require "erb"
require "json"
require_relative "../utils/item_type_inferrer"
require_relative "../utils/text_truncator"

module WebTechFeeder
  module Processor
    # Shared logic for all AI processors: prompt building, fallback, category iteration.
    # Subclasses only need to implement #call_api(prompt) -> parsed JSON hash.
    class BaseProcessor
      RATE_LIMIT_DELAY = 5
      MAX_RETRIES = 3
      ITEMS_LIMIT_FOR_AI = 15
      FALLBACK_ITEMS_LIMIT = 5

      CATEGORY_TITLES = {
        frontend: "前端技術動態",
        backend: "後端技術動態",
        devops: "DevOps 相關資訊"
      }.freeze

      attr_reader :config, :logger

      def initialize(config)
        @config = config
        @logger = config.logger
      end

      def process(raw_data)
        total = count_items(raw_data)
        logger.info("Processing #{total} items across #{raw_data.size} categories via #{provider_name}")

        result = {}

        raw_data.each_with_index do |(category, items), index|
          if items.empty?
            result[category] = { section_title: CATEGORY_TITLES[category], items: [] }
            next
          end

          logger.info("Processing category: #{category} (#{items.size} items)")
          result[category] = process_category(category, items)

          if index < raw_data.size - 1
            logger.info("Waiting #{RATE_LIMIT_DELAY}s before next API call")
            sleep(RATE_LIMIT_DELAY)
          end
        end

        result
      end

      # Subclasses must implement: returns provider display name
      def provider_name
        raise NotImplementedError
      end

      # Subclasses must implement: sends prompt, returns parsed response text (String)
      def call_api(prompt)
        raise NotImplementedError
      end

      private

      def process_category(category, items)
        limited = items.take(ITEMS_LIMIT_FOR_AI)
        prompt = build_category_prompt(category, limited)
        retries = 0
        begin
          text = call_api(prompt)
          parse_response_text(text, category)
        rescue StandardError => e
          retries += 1
          reason = "#{e.class}: #{e.message}"
          if retries <= MAX_RETRIES
            wait = 30 * (2**(retries - 1))
            logger.warn("AI processing error for #{category}. Retry #{retries}/#{MAX_RETRIES} in #{wait}s. reason=#{reason[0..200]}")
            sleep(wait)
            retry
          end

          bt = Array(e.backtrace).first(3)&.join(" | ")
          logger.error("AI processing failed for #{category}. reason=#{reason}")
          logger.error("AI processing backtrace for #{category}: #{bt}") if bt && !bt.empty?
          fallback_category(category, items)
        end
      end

      PROMPT_TEMPLATE_PATH = File.expand_path("../prompts/category_digest.erb", __dir__)

      def build_category_prompt(category, items)
        section_title = CATEGORY_TITLES[category]
        raw_data = format_items(items)

        template = File.read(PROMPT_TEMPLATE_PATH)
        ERB.new(template, trim_mode: "-").result(binding)
      end

      # Per-item body truncation; enriched items (with comments) may be longer
      BODY_TRUNCATE = 800

      def format_items(items)
        lines = []
        items.each do |item|
          lines << "- Title: #{item.title}"
          lines << "  URL: #{item.url}"
          lines << "  Published: #{item.published_at}"
          lines << "  Source: #{item.source}"
          body = item.body.to_s.strip
          if body.length.positive?
            truncated = Utils::TextTruncator.truncate(body, max_length: BODY_TRUNCATE)
            lines << "  Body: #{truncated}"
          end
          lines << ""
        end
        lines.join("\n")
      end

      def parse_response_text(text, category)
        raise "Empty AI response for #{category}" if text.nil? || text.empty?

        cleaned = text.gsub(/\A```json\s*/, "").gsub(/\s*```\z/, "").strip

        extracted = extract_json_object(cleaned)
        parsed = try_parse_json(cleaned) ||
                 try_parse_json(extracted) ||
                 try_parse_json(cleaned.gsub(/\\([^"\\\/bfnrtu])/, '\1')) ||
                 (extracted && try_parse_json(extracted.gsub(/\\([^"\\\/bfnrtu])/, '\1')))

        raise "Invalid JSON in AI response for #{category}" unless parsed

        parsed[:section_title] ||= CATEGORY_TITLES[category]
        parsed[:items] ||= []
        parsed[:items].each { |item| normalize_item_type!(item) }
        parsed
      end

      def normalize_item_type!(item)
        return unless item[:item_type].to_s.strip.empty?

        item[:item_type] = infer_item_type(item)
      end

      def infer_item_type(item)
        Utils::ItemTypeInferrer.infer(item)
      end

      def try_parse_json(str)
        return nil if str.nil? || str.empty?

        parsed = JSON.parse(str, symbolize_names: true)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError, TypeError
        nil
      end

      # Extract the first top-level JSON object when model prepends narrative text
      def extract_json_object(str)
        start_idx = str.index("{")
        return nil unless start_idx

        i = start_idx
        depth = 0
        in_string = false
        escape_next = false

        while i < str.length
          c = str[i]

          if escape_next
            escape_next = false
            i += 1
            next
          end

          if in_string
            escape_next = true if c == "\\"
            in_string = false if c == '"'
            i += 1
            next
          end

          if c == '"'
            in_string = true
            i += 1
            next
          end

          if c == "{"
            depth += 1
          elsif c == "}"
            depth -= 1
            return str[start_idx..i] if depth == 0
          end

          i += 1
        end

        nil
      end

      # Fallback when AI fails - clean, readable output from raw data
      def fallback_category(category, items)
        logger.warn("Using fallback for #{category} (#{items.size} items)")

        unique_items = items.uniq { |i| i.url }.sort_by { |i| i.published_at || Time.at(0) }.reverse

        {
          section_title: CATEGORY_TITLES[category],
          items: unique_items.first(FALLBACK_ITEMS_LIMIT).map { |item| format_fallback_item(item) }
        }
      end

      def format_fallback_item(item)
        title = item.title.to_s.strip
        summary = clean_summary(item.body.to_s)
        importance = guess_importance(item)
        importance = "high" if %w[medium low].include?(importance)

        {
          title: title,
          summary: summary.empty? ? "#{item.source} - #{item.published_at&.strftime('%Y-%m-%d')}" : summary,
          importance: importance,
          item_type: infer_item_type_from_raw(item),
          source_url: item.url,
          source_name: item.source
        }
      end

      def infer_item_type_from_raw(item)
        Utils::ItemTypeInferrer.infer(item)
      end

      def clean_summary(body)
        return "" if body.nil? || body.strip.empty?

        text = body.split("\n").first.to_s.strip
        text = text.sub(/\AState:.*?\|.*?\n?/, "").strip
        text.length > 200 ? "#{text[0...200]}..." : text
      end

      def guess_importance(item)
        title_lower = item.title.to_s.downcase
        source_lower = item.source.to_s.downcase

        if title_lower.include?("security") || title_lower.include?("cve") || source_lower.include?("advisory")
          "critical"
        elsif title_lower.include?("released") || title_lower.include?("release")
          "high"
        elsif source_lower.include?("issue") || source_lower.include?("pr")
          "low"
        else
          "medium"
        end
      end

      def count_items(raw_data)
        raw_data.values.sum { |items| items.size }
      end
    end
  end
end
