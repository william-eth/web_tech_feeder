# frozen_string_literal: true

require "time"
require "feedjira"
require_relative "base_collector"

module WebTechFeeder
  module Collectors
    # Fetches and parses RSS/Atom feeds, filtering entries from the past week.
    class RssCollector < BaseCollector
      # Maximum number of redirects to follow
      MAX_REDIRECTS = 5

      # feeds: Array of { url:, name: } hashes
      def initialize(config, feeds:)
        super(config)
        @feeds = feeds
      end

      def collect
        items = []

        @feeds.each do |feed_config|
          url = feed_config[:url]
          name = feed_config[:name]

          logger.info("Fetching RSS feed: #{name} (#{url})")
          entries = fetch_feed(url)

          entries.each do |entry|
            published_at = entry_published_at(entry)
            next unless recent?(published_at)

            items << Item.new(
              title: entry.title&.strip,
              url: entry.url || entry.entry_id,
              published_at: published_at,
              body: truncate_body(extract_summary(entry)),
              source: name
            )
          end
        rescue StandardError => e
          logger.warn("Failed to fetch RSS feed #{name}: #{e.message}")
        end

        items
      end

      private

      # Fetch feed with manual redirect following (handles 301/302/307/308)
      def fetch_feed(url)
        conn = Faraday.new do |f|
          f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                            exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
          f.adapter Faraday.default_adapter
          f.headers["User-Agent"] = "WebTechFeeder/1.0"
          f.options.timeout = 30
          f.options.open_timeout = 10
        end

        response = follow_redirects(conn, url)
        feed = Feedjira.parse(response.body)
        feed.entries
      end

      # Manually follow redirects since Faraday core doesn't do it by default
      def follow_redirects(conn, url, limit = MAX_REDIRECTS)
        raise "Too many redirects" if limit.zero?

        response = conn.get(url)

        case response.status
        when 200
          response
        when 301, 302, 303, 307, 308
          redirect_url = response.headers["location"]
          logger.info("  Following redirect -> #{redirect_url}")
          follow_redirects(conn, redirect_url, limit - 1)
        else
          raise "Unexpected response status #{response.status} for #{url}"
        end
      end

      def entry_published_at(entry)
        time = entry.published || entry.updated
        time.is_a?(Time) ? time : safe_parse_time(time)
      end

      # Extract a clean text summary from feed entry
      def extract_summary(entry)
        text = entry.summary || entry.content || ""
        # Strip HTML tags for a cleaner summary
        text.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
      end
    end
  end
end
