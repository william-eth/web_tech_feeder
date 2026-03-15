# frozen_string_literal: true

require "time"
require_relative "base_collector"

module WebTechFeeder
  module Collectors
    # Fetches recent articles from the Dev.to public API.
    # Each feed entry is a JSON endpoint (e.g. /api/articles?tag=react&top=7).
    class DevtoCollector < BaseCollector
      DEVTO_BASE_URL = "https://dev.to"
      MAX_ARTICLES_PER_FEED = 20

      # feeds: Array of { url:, name: } hashes where url is the full API URL
      def initialize(config, feeds:)
        super(config)
        @feeds = feeds
      end

      def collect
        items = []

        @feeds.each do |feed_config|
          name = feed_config[:name]
          url = feed_config[:url]

          logger.info("Fetching Dev.to API: #{name} (#{url})")
          articles = fetch_articles(url)

          articles.each do |article|
            published_at = safe_parse_time(article["published_at"] || article["created_at"])
            next unless recent?(published_at)

            items << Item.new(
              title: article["title"],
              url: article["url"] || article["canonical_url"],
              published_at: published_at,
              body: build_body(article),
              source: name,
              metadata: { primary_source: true }
            )
          end
        rescue Faraday::Error => e
          logger.warn("Failed to fetch Dev.to feed #{name}: #{e.message}")
        rescue JSON::ParserError => e
          logger.warn("Failed to parse Dev.to response for #{name}: #{e.message}")
        end

        items
      end

      private

      def fetch_articles(url)
        uri = URI.parse(url)
        conn = build_connection("#{uri.scheme}://#{uri.host}")
        path_with_query = uri.path
        path_with_query += "?#{uri.query}" if uri.query
        response = conn.get(path_with_query)
        articles = JSON.parse(response.body)
        articles.first(MAX_ARTICLES_PER_FEED)
      end

      def build_body(article)
        parts = []
        parts << article["description"] if article["description"]&.strip&.length&.positive?
        tags = article["tag_list"]
        parts << "Tags: #{tags.join(', ')}" if tags.is_a?(Array) && tags.any?
        parts.join("\n\n")
      end
    end
  end
end
