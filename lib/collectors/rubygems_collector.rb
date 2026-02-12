# frozen_string_literal: true

require "time"
require_relative "base_collector"

module WebTechFeeder
  module Collectors
    # Fetches recent version information for specified gems from the RubyGems API.
    class RubygemsCollector < BaseCollector
      RUBYGEMS_API_URL = "https://rubygems.org"

      # gem_names: Array of gem name strings, e.g. ["pg", "puma", "redis"]
      def initialize(config, gem_names:)
        super(config)
        @gem_names = gem_names
      end

      def collect
        items = []

        @gem_names.each do |gem_name|
          logger.info("Fetching RubyGems versions for: #{gem_name}")
          versions = fetch_versions(gem_name)

          versions.each do |version_info|
            created_at = safe_parse_time(version_info["created_at"])
            next unless recent?(created_at)

            items << Item.new(
              title: "#{gem_name} #{version_info['number']} released",
              url: "https://rubygems.org/gems/#{gem_name}/versions/#{version_info['number']}",
              published_at: created_at,
              body: version_info["summary"] || version_info["description"] || "",
              source: "RubyGems - #{gem_name}"
            )
          end
        rescue Faraday::Error => e
          logger.warn("Failed to fetch gem info for #{gem_name}: #{e.message}")
        end

        items
      end

      private

      def fetch_versions(gem_name)
        conn = build_connection(RUBYGEMS_API_URL)
        response = conn.get("/api/v1/versions/#{gem_name}.json")
        all_versions = JSON.parse(response.body)
        # Only return recent versions (limit check to latest 10 to avoid processing too many)
        all_versions.first(10)
      end
    end
  end
end
