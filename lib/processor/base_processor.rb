# frozen_string_literal: true

require "erb"
require "json"
require_relative "../utils/cve_enricher"
require_relative "../utils/item_type_inferrer"
require_relative "../utils/security_signal"
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
      PROMPT_TEMPLATE_PATH = File.expand_path("../prompts/category_digest.erb", __dir__)
      BODY_TRUNCATE = 800
      ADVISORY_MIN_IMPORTANCE = %w[critical high medium].freeze
      SECURITY_DETAILS_UNAVAILABLE = "來源未提供完整漏洞細節。"
      NVD_SEVERITY_MAP = {
        "CRITICAL" => "critical",
        "HIGH" => "high",
        "MEDIUM" => "medium",
        "LOW" => "low"
      }.freeze

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
        categories = raw_data.to_a
        api_dead = false

        categories.each_with_index do |(category, items), index|
          if items.empty?
            result[category] = { section_title: CATEGORY_TITLES[category], items: [] }
            next
          end

          if api_dead
            logger.warn("Skipping AI for #{category} due to earlier fatal API error, using fallback")
            result[category] = fallback_category(category, items)
            next
          end

          logger.info("Processing category: #{category} (#{items.size} items)")
          result[category] = process_category(category, items)

          if index < categories.size - 1
            logger.info("Waiting #{RATE_LIMIT_DELAY}s before next API call")
            sleep(RATE_LIMIT_DELAY)
          end
        rescue Processor::FatalApiError => e
          api_dead = true
          reason = "#{e.class}: #{e.message}"
          logger.error("Fatal API error for #{category}, aborting AI for remaining categories. reason=#{reason}")
          bt = Array(e.backtrace).first(3)&.join(" | ")
          logger.error("AI processing backtrace for #{category}: #{bt}") if bt && !bt.empty?
          result[category] = fallback_category(category, items)
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
        prioritized = prioritize_security_items(items)
        prioritized = prioritize_keyword_items(category, prioritized)
        limited = prioritized.take(ITEMS_LIMIT_FOR_AI)
        prompt = build_category_prompt(category, limited)
        retries = 0
        begin
          text = call_api(prompt)
          parsed = parse_response_text(text, category)
          ensure_security_coverage(parsed, items)
        rescue Processor::FatalApiError
          raise
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

      # Move items with CVE/GHSA in title to front so they survive the
      # ITEMS_LIMIT_FOR_AI truncation and reach the AI prompt.
      def prioritize_security_items(items)
        sec, rest = items.partition { |i| Utils::SecuritySignal.explicit_security_id_signal?(i.title) }
        sec + rest
      end

      # For categories with evergreen keywords (e.g. frontend), boost items
      # from primary sources or matching keywords so they survive truncation.
      # Items already prioritized by security stay at the front.
      def prioritize_keyword_items(category, items)
        keywords = config.evergreen_keywords(category)
        return items if keywords.empty?

        items.each do |item|
          next unless item.respond_to?(:metadata)

          item.metadata ||= {}
          text = "#{item.title} #{item.body}".downcase
          item.metadata[:keyword_match] = keywords.any? { |kw| text.include?(kw) }
          item.metadata[:primary_source] = true if item.metadata[:primary_source]
        end

        high_value, rest = items.partition { |i| keyword_high_value?(i) }
        sec_items, non_sec_high = high_value.partition { |i| Utils::SecuritySignal.explicit_security_id_signal?(i.title) }
        sec_rest, normal_rest = rest.partition { |i| Utils::SecuritySignal.explicit_security_id_signal?(i.title) }
        sec_items + sec_rest + non_sec_high + normal_rest
      end

      def keyword_high_value?(item)
        meta = item.respond_to?(:metadata) ? item.metadata : nil
        return false unless meta.is_a?(Hash)

        meta[:keyword_match] || meta[:primary_source]
      end

      def build_category_prompt(category, items)
        section_title = CATEGORY_TITLES[category]
        raw_data = format_items(items)

        template = File.read(PROMPT_TEMPLATE_PATH)
        ERB.new(template, trim_mode: "-").result_with_hash(
          section_title: section_title,
          raw_data: raw_data
        )
      end

      def format_items(items)
        lines = []
        items.each do |item|
          lines << "- Title: #{item.title}"
          lines << "  URL: #{item.url}"
          lines << "  Published: #{item.published_at}"
          lines << "  Source: #{item.source}"
          lines << "  Priority: high-value" if keyword_high_value?(item)
          body = item.body.to_s.strip
          if body.length.positive?
            truncated = Utils::TextTruncator.truncate(body, max_length: BODY_TRUNCATE)
            lines << "  Body: #{truncated}"
          end
          format_metadata_lines(lines, item.metadata) if item.respond_to?(:metadata) && item.metadata.is_a?(Hash)
          lines << ""
        end
        lines.join("\n")
      end

      def format_metadata_lines(lines, meta)
        lines << "  CVE: #{meta[:cve_id]}" if meta[:cve_id]
        lines << "  CVSS: #{meta[:cvss_score]}" if meta[:cvss_score]
        lines << "  Severity: #{meta[:severity]}" if meta[:severity]
        Array(meta[:vulnerabilities]).each do |v|
          parts = []
          parts << "pkg=#{v[:package]}" if v[:package]
          parts << "range=#{v[:vulnerable_range]}" if v[:vulnerable_range]
          parts << "patched=#{v[:patched_version]}" if v[:patched_version]
          lines << "  Vulnerability: #{parts.join(', ')}" if parts.any?
        end
      end

      def parse_response_text(text, category)
        raise "Empty AI response for #{category}" if text.nil? || text.empty?

        cleaned = text.gsub(/\A```json\s*/, "").gsub(/\s*```\z/, "").strip

        extracted = extract_json_object(cleaned)
        parsed = try_parse_json(cleaned) ||
                 try_parse_json(extracted) ||
                 try_parse_json(cleaned.gsub(%r{\\([^"\\/bfnrtu])}, '\1')) ||
                 (extracted && try_parse_json(extracted.gsub(%r{\\([^"\\/bfnrtu])}, '\1')))

        raise "Invalid JSON in AI response for #{category}" unless parsed

        parsed[:section_title] ||= CATEGORY_TITLES[category]
        parsed[:items] ||= []
        parsed[:items].each { |item| normalize_item_type!(item) }
        parsed
      end

      def ensure_security_coverage(parsed, raw_items)
        items = Array(parsed[:items])
        return parsed if items.empty?

        normalize_advisory_importance!(items, raw_items)

        # Only count an existing advisory as sufficient when it has real
        # security material AND its importance meets the minimum threshold.
        # AI sometimes outputs advisory items with low importance that then
        # get dropped by the general importance filter, leaving the security
        # section empty.
        has_qualified_advisory = items.any? do |item|
          next false unless (item[:item_type] || "").downcase == "advisory"
          next false unless ADVISORY_MIN_IMPORTANCE.include?((item[:importance] || "").downcase)

          advisory_security_signal?(item[:title]) || advisory_security_signal?(item[:summary])
        end
        return parsed if has_qualified_advisory

        existing_urls = items.map { |i| i[:source_url].to_s.strip }
        candidate = pick_security_candidate(raw_items, existing_urls)
        return parsed unless candidate

        items << build_advisory_item_from_raw(candidate)
        parsed[:items] = items.uniq { |i| [i[:source_url].to_s.strip, (i[:item_type] || "").downcase] }
        parsed
      end

      def normalize_advisory_importance!(items, raw_items)
        raw_metadata_by_url = build_raw_metadata_by_url(raw_items)

        items.each do |item|
          next unless (item[:item_type] || "").downcase == "advisory"

          normalized = normalized_advisory_importance(item, raw_metadata_by_url)
          item[:importance] = normalized if normalized
        end
      end

      def build_raw_metadata_by_url(raw_items)
        Array(raw_items).each_with_object({}) do |raw_item, lookup|
          next unless raw_item.respond_to?(:metadata)
          next unless raw_item.metadata.is_a?(Hash)

          url = raw_item.url.to_s.strip
          next if url.empty?

          lookup[url] = raw_item.metadata
        end
      end

      def normalized_advisory_importance(item, raw_metadata_by_url)
        score = advisory_cvss_score(item, raw_metadata_by_url)
        return importance_from_cvss_score(score) if score

        severity = advisory_severity_label(item, raw_metadata_by_url)
        return importance_from_severity_label(severity) if severity

        nil
      end

      def advisory_cvss_score(item, raw_metadata_by_url)
        metadata = advisory_raw_metadata(item, raw_metadata_by_url)
        raw_score = metadata&.[](:cvss_score) || metadata&.[]("cvss_score")
        return raw_score.to_f if raw_score

        match = item[:summary].to_s.match(/\bCVSS(?:\s+Rating:)?\s*(\d+(?:\.\d+)?)\b/i)
        match && match[1].to_f
      end

      def advisory_severity_label(item, raw_metadata_by_url)
        metadata = advisory_raw_metadata(item, raw_metadata_by_url)
        raw_severity = metadata&.[](:severity) || metadata&.[]("severity")
        return raw_severity if raw_severity.to_s.strip.length.positive?

        summary = item[:summary].to_s
        summary[/風險等級[:：]\s*(Critical|High|Medium|Low|Important)/i, 1] ||
          summary[/CVSS(?:\s+Rating:)?\s*\d+(?:\.\d+)?\s*[（(](Critical|High|Medium|Low|Important)[）)]/i, 1]
      end

      def advisory_raw_metadata(item, raw_metadata_by_url)
        raw_metadata_by_url[item[:source_url].to_s.strip]
      end

      def importance_from_cvss_score(score)
        case score.to_f
        when 9.0..10.0 then "critical"
        when 7.0...9.0 then "high"
        when 4.0...7.0 then "medium"
        else "low"
        end
      end

      def importance_from_severity_label(severity)
        {
          "CRITICAL" => "critical",
          "HIGH" => "high",
          "IMPORTANT" => "high",
          "MEDIUM" => "medium",
          "LOW" => "low"
        }[severity.to_s.upcase]
      end

      # Select the best raw item for advisory fallback injection.
      # Priority: explicit CVE/GHSA in body/title with unique URL >
      # explicit CVE/GHSA anywhere > title-level signal with unique URL >
      # any candidate with unique URL > any candidate.
      def pick_security_candidate(raw_items, existing_urls = [])
        candidates = Array(raw_items).select { |i| raw_explicit_security_candidate?(i) }
        return nil if candidates.empty?

        has_explicit_id = ->(i) { Utils::SecuritySignal.explicit_security_id_signal?(i.title) || Utils::SecuritySignal.explicit_security_id_signal?(i.body) }
        unique_url = ->(i) { !existing_urls.include?(i.url.to_s.strip) }

        candidates.find { |i| has_explicit_id.call(i) && unique_url.call(i) } ||
          candidates.find { |i| has_explicit_id.call(i) } ||
          candidates.find { |i| advisory_security_signal?(i.title) && unique_url.call(i) } ||
          candidates.find { |i| unique_url.call(i) } ||
          candidates.first
      end

      def raw_explicit_security_candidate?(item)
        Utils::SecuritySignal.explicit_security_id_signal?(item.title) ||
          Utils::SecuritySignal.explicit_security_id_signal?(item.body) ||
          advisory_security_signal?(item.title) ||
          advisory_security_signal?(item.body)
      end

      def advisory_security_signal?(text)
        Utils::SecuritySignal.advisory_security_signal?(text)
      end

      def build_advisory_item_from_raw(item)
        cve = extract_cve_id(item.title.to_s, item.body.to_s)
        cvss = cve ? Utils::CveEnricher.fetch_cvss(cve, logger: logger) : nil
        framework = infer_framework_from_source(item.source.to_s, item.title.to_s)
        title = cve ? "#{framework} 安全性通報：#{cve}" : "#{framework} 安全性通報"
        importance = cvss ? nvd_severity_to_importance(cvss[:severity]) : "high"

        {
          title: title,
          summary: advisory_summary_from_raw(item, cve, cvss: cvss),
          importance: importance,
          item_type: "advisory",
          framework_or_package: framework,
          source_url: item.url,
          source_name: item.source
        }
      end

      def nvd_severity_to_importance(severity)
        NVD_SEVERITY_MAP[severity.to_s.upcase] || "high"
      end

      def advisory_summary_from_raw(item, cve, cvss: nil)
        desc = extract_security_description(item.body.to_s)
        # Prefer CVE description from enricher over low-quality raw body extraction
        desc = cvss[:description] if cvss&.dig(:description) && (desc == SECURITY_DETAILS_UNAVAILABLE || github_template_body?(item.body.to_s))

        vuln_lines = ["🛡️ 漏洞說明"]
        if cvss
          cvss_label = "CVSS #{cvss[:score]}（#{cvss[:severity].capitalize}）"
          cvss_label += "（來源：#{cvss[:source]}）" if cvss[:source] && cvss[:source] != "NVD"
          vuln_lines << "• #{cvss_label}"
        else
          vuln_lines << "• 風險等級：High（AI 判斷）"
          vuln_lines << "• CVSS：無法確認"
        end
        vuln_lines << "• #{cve} 相關漏洞通報。" if cve && !desc.include?(cve.to_s)
        vuln_lines << "• #{desc}" unless desc == SECURITY_DETAILS_UNAVAILABLE && cve

        [
          *vuln_lines,
          "⚔️ 攻擊方式",
          "• 目前來源未提供完整攻擊鏈；建議視為可被濫用的已知弱點並優先處理。",
          "🔧 修正建議",
          "• 優先升級至來源公告建議版本。",
          "• 短期緩解：限制外部輸入與高風險路徑，並加強監控告警。"
        ].join("\n")
      end

      def extract_security_description(body)
        return SECURITY_DETAILS_UNAVAILABLE if body.to_s.strip.empty?
        return SECURITY_DETAILS_UNAVAILABLE if github_template_body?(body)

        desc = extract_section_header_description(body)
        return desc if desc

        desc = extract_vulnerability_sentence(body)
        return desc if desc

        first = clean_summary(body)
        return SECURITY_DETAILS_UNAVAILABLE if first.empty? || first.match?(/\Arelease notes:?/i)

        first
      end

      # Look for a section header right before the CVE mention.
      # Many security advisories use patterns like:
      #   "crypto/x509: incorrect enforcement of email constraints\n\n- When verifying..."
      #   "Buffer overflow in Zlib::GzipReader\n\nThe zstream_buffer_ungets function..."
      def extract_section_header_description(body)
        lines = body.to_s.split(/\n+/).map(&:strip).reject(&:empty?)
        cve_line_idx = lines.index { |l| l.match?(/\bCVE-\d{4}-\d+\b/i) || l.match?(/\bThis is CVE-/i) }
        return nil unless cve_line_idx

        header = nil
        explanation = nil

        (cve_line_idx - 1).downto(0) do |i|
          line = lines[i].sub(/\A\*{1,2}\s*/, "").sub(/\A[-•]\s*/, "").strip
          next if line.empty? || line.match?(/\A(State:|Description:|---|###|http|<!-)/i)
          next if github_template_field?(lines[i])

          if line.length < 120 && !line.match?(/\.\s*\z/)
            header = line
            explanation = lines[i + 1] if lines[i + 1] && lines[i + 1] != lines[cve_line_idx]
            break
          end

          next unless line.length >= 20 && Utils::SecuritySignal.vulnerability_keyword_signal?(line)

          explanation = line
          header_candidate = lines[i - 1] if i.positive?
          header = header_candidate if header_candidate && header_candidate.length < 120 && !header_candidate.match?(/\.\s*\z/)
          break
        end

        return nil unless header || explanation

        parts = [header, explanation].compact.map { |s| truncate_to(s, 200) }
        parts.join(". ").sub(/\.\.\z/, ".")
      end

      # Find the first sentence with a vulnerability keyword, skipping bare CVE reference lines.
      def extract_vulnerability_sentence(body)
        text = body.to_s.gsub(/\s+/, " ").strip
        sentences = text.split(/(?<=[.!?])\s+/)

        sentences.find do |s|
          next false if s.match?(/\AThis is CVE-/i)
          next false if s.strip.length < 15

          Utils::SecuritySignal.vulnerability_keyword_signal?(s)
        end&.strip
      end

      def truncate_to(text, max)
        return text if text.length <= max

        cut = text[0...max]
        last_space = cut.rindex(" ")
        cut = cut[0...last_space] if last_space && (max - last_space) < 20
        "#{cut.rstrip}..."
      end

      # GitHub issue templates use bold field labels like
      # "**What would you like to be added**:" that are not vulnerability descriptions.
      def github_template_field?(raw_line)
        raw_line.match?(/\A\s*\*{1,2}[^*]+\*{1,2}\s*:\s*\z/) && raw_line.strip.length < 60
      end

      # Detect GitHub issue bodies that are feature-request templates rather
      # than security advisory prose. These typically contain template field
      # markers and HTML comments with boilerplate instructions.
      def github_template_body?(body)
        text = body.to_s
        text.include?("**What would you like") ||
          text.include?("**Why is this needed") ||
          text.include?("**Additional context") ||
          text.match?(/<!--.*template.*-->/im)
      end

      def extract_cve_id(*texts)
        texts.each do |text|
          m = text.to_s.match(/\b(CVE-\d{4}-\d+)\b/i)
          return m[1].upcase if m
        end
        nil
      end

      def infer_framework_from_source(source, title)
        s = "#{source} #{title}".downcase
        return "Ruby" if s.include?("ruby")
        return "Rails" if s.include?("rails")
        return "Node.js" if s.include?("node")
        return "Nginx" if s.include?("nginx")
        return "Kubernetes" if s.include?("kubernetes") || s.include?("k8s")
        return "Docker" if s.include?("docker") || s.include?("moby")
        return "OpenTofu" if s.include?("opentofu")
        return "Go" if s.match?(/\bgo\b/)
        return "PostgreSQL" if s.include?("postgres")
        return "Redis" if s.include?("redis") || s.include?("valkey")
        return "Grafana" if s.include?("grafana")
        return "Amazon EKS AMI" if s.include?("eks-ami") || s.include?("eks ami") || s.include?("amazon-eks")
        return "React" if s.include?("react")
        return "Next.js" if s.include?("next.js") || s.include?("nextjs")

        "Security"
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
            return str[start_idx..i] if depth.zero?
          end

          i += 1
        end

        nil
      end

      # Fallback when AI fails - clean, readable output from raw data
      def fallback_category(category, items)
        logger.warn("Using fallback for #{category} (#{items.size} items)")

        unique_items = items.uniq(&:url).sort_by { |i| i.published_at || Time.at(0) }.reverse

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
          item_type: infer_item_type(item),
          source_url: item.url,
          source_name: item.source
        }
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
        raw_data.values.sum(&:size)
      end
    end
  end
end
