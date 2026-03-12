# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"

module WebTechFeeder
  module Utils
    # Fetches CVSS score and severity for a given CVE ID.
    # Primary source: NVD API 2.0. Fallback: Amazon Linux Security Center (ALAS).
    # Results are cached for the lifetime of the Ruby process (run-level cache).
    # Returns nil gracefully on any network/parse error.
    module CveEnricher
      NVD_API_URL = "https://services.nvd.nist.gov/rest/json/cves/2.0"
      ALAS_BASE_URL = "https://explore.alas.aws.amazon.com"
      REQUEST_TIMEOUT = 10
      OPEN_TIMEOUT = 5
      CVSS_METRIC_KEYS = %i[cvssMetricV31 cvssMetricV30 cvssMetricV40].freeze

      # Amazon severity labels → standard CVSS severity
      ALAS_SEVERITY_MAP = {
        "critical" => "CRITICAL",
        "important" => "HIGH",
        "medium" => "MEDIUM",
        "low" => "LOW"
      }.freeze

      @cache = {}
      @logger = nil
      @nvd_connection = nil
      @alas_connection = nil

      class << self
        attr_writer :logger

        # Returns { score: Float, severity: String, source: String, description: String? } or nil.
        def fetch_cvss(cve_id, logger: nil)
          id = cve_id.to_s.strip.upcase
          return nil if id.empty? || !id.match?(/\ACVE-\d{4}-\d+\z/)

          return @cache[id] if @cache.key?(id)

          log = logger || @logger
          log&.info("CveEnricher: fetching CVSS for #{id}")

          nvd = fetch_nvd_data(id, log)
          result = if nvd && nvd[:score]
                     nvd.merge(source: "NVD")
                   else
                     alas = fetch_cvss_from_alas(id, log)
                     if alas
                       alas[:description] ||= nvd[:description] if nvd&.dig(:description)
                       alas
                     end
                   end

          @cache[id] = result

          if result
            log&.info("CveEnricher: #{id} -> CVSS #{result[:score]} (#{result[:severity]}) via #{result[:source]}")
          else
            log&.info("CveEnricher: #{id} -> no CVSS data available from any source")
          end

          result
        rescue StandardError => e
          log&.warn("CveEnricher: failed to fetch #{id}: #{e.class}: #{e.message}")
          @cache[id] = nil
          nil
        end

        def reset_cache!
          @cache = {}
        end

        private

        # --- NVD API 2.0 ---

        # Returns partial result even without metrics (e.g. description-only).
        def fetch_nvd_data(cve_id, _log)
          resp = nvd_connection.get("", { cveId: cve_id })
          return nil unless resp.status == 200

          data = JSON.parse(resp.body, symbolize_names: true)
          parse_nvd_data(data)
        rescue StandardError
          nil
        end

        def parse_nvd_data(data)
          return nil unless data.is_a?(Hash)

          vulns = data[:vulnerabilities]
          return nil unless vulns.is_a?(Array) && !vulns.empty?

          cve_item = vulns.first&.dig(:cve)
          return nil unless cve_item.is_a?(Hash)

          result = {}

          metrics = cve_item[:metrics]
          if metrics.is_a?(Hash) && !metrics.empty?
            metric = extract_metric(metrics)
            result.merge!(metric) if metric
          end

          desc = extract_nvd_description(cve_item)
          result[:description] = desc if desc

          result.empty? ? nil : result
        end

        def extract_nvd_description(cve_item)
          descs = cve_item[:descriptions]
          return nil unless descs.is_a?(Array)

          en = descs.find { |d| d[:lang] == "en" }
          normalize_description((en || descs.first)&.dig(:value))
        end

        def extract_metric(metrics)
          CVSS_METRIC_KEYS.each do |key|
            parsed = extract_base_score(metrics[key])
            return parsed if parsed
          end
          nil
        end

        def extract_base_score(entries)
          cvss = entries.is_a?(Array) ? entries.first&.dig(:cvssData) : nil
          return nil unless cvss.is_a?(Hash)

          score = cvss[:baseScore]
          return nil unless score

          { score: score.to_f, severity: cvss[:baseSeverity].to_s.upcase }
        end

        # --- Amazon Linux Security Center (ALAS) ---

        def fetch_cvss_from_alas(cve_id, log)
          url = "#{ALAS_BASE_URL}/#{cve_id}.html"
          resp = alas_connection.get(url)
          return nil unless resp.status == 200

          result = parse_alas_page(resp.body)
          result&.merge(source: "Amazon ALAS")
        rescue StandardError => e
          log&.debug("CveEnricher: ALAS fallback failed for #{cve_id}: #{e.class}: #{e.message}")
          nil
        end

        def parse_alas_page(html)
          score = extract_alas_score(html)
          return nil unless score

          severity = extract_alas_severity(html) || severity_from_score(score)
          desc = extract_alas_description(html)
          result = { score: score, severity: severity }
          result[:description] = desc if desc
          result
        end

        def extract_alas_score(html)
          # Strategy 1: find score in "CVSS v3 Base Score" section.
          # Allow multiple HTML tags between the heading text and the score value.
          base_match = html.match(/CVSS\s+v3[^<]*Base\s+Score.*?(\d+\.\d+)/im)
          return base_match[1].to_f if base_match

          # Strategy 2: score appears near CVSS vector string in the scores table.
          vector_region = html[%r{(\d+\.\d+).{0,200}CVSS:3\.\d/AV:}m]
          if vector_region
            score_m = vector_region.match(/(\d+\.\d+)/)
            return score_m[1].to_f if score_m
          end

          nil
        end

        def extract_alas_severity(html)
          sev_match = html.match(/(Critical|Important|Medium|Low)\s*severity/im)
          return ALAS_SEVERITY_MAP[sev_match[1].downcase] if sev_match

          sev_match = html.match(/severity\s*(?:<[^>]*>\s*)*(Critical|Important|Medium|Low)/im)
          return ALAS_SEVERITY_MAP[sev_match[1].downcase] if sev_match

          nil
        end

        # Extract the CVE description from the ALAS page for use as advisory content.
        def extract_alas_description(html)
          text = html.gsub(/<[^>]+>/, " ").gsub(/&[a-z#0-9]+;/, " ")
          desc_match = text.match(/Description\s+(.+?)(?:Severity|Affected|CVSS|\z)/im)
          return nil unless desc_match

          normalize_description(desc_match[1].gsub(/\s+/, " "))
        end

        def normalize_description(value, max_length: 300)
          text = value.to_s.strip
          return nil if text.empty? || text.length < 10

          text.length > max_length ? "#{text[0...(max_length - 3)]}..." : text
        end

        def severity_from_score(score)
          return "CRITICAL" if score >= 9.0
          return "HIGH" if score >= 7.0
          return "MEDIUM" if score >= 4.0
          return "LOW" if score >= 0.1

          "NONE"
        end

        # --- Connections ---

        def nvd_connection
          @nvd_connection ||= Faraday.new(url: NVD_API_URL) do |f|
            f.options.timeout = REQUEST_TIMEOUT
            f.options.open_timeout = OPEN_TIMEOUT
            f.request :retry, max: 2, interval: 1, backoff_factor: 2,
                              exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed,
                                           Errno::ECONNRESET, Errno::EPIPE]
            f.adapter Faraday.default_adapter
          end
        end

        def alas_connection
          @alas_connection ||= Faraday.new do |f|
            f.options.timeout = REQUEST_TIMEOUT
            f.options.open_timeout = OPEN_TIMEOUT
            f.request :retry, max: 1, interval: 1,
                              exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
            f.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end
