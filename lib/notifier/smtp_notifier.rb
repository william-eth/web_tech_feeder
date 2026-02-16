# frozen_string_literal: true

require "mail"
require "erb"
require "google/apis/gmail_v1"
require "googleauth"

module WebTechFeeder
  module Notifier
    # Sends the digest email via Gmail API with OAuth 2.0 refresh token.
    # Builds RFC 2822 message with the mail gem, then sends via Gmail API.
    class SmtpNotifier
      TEMPLATE_PATH = File.expand_path("../templates/digest.html.erb", __dir__)
      GMAIL_SEND_SCOPE = "https://www.googleapis.com/auth/gmail.send"

      attr_reader :config, :logger

      def initialize(config)
        @config = config
        @logger = config.logger
      end

      # digest_data: Hash with :frontend, :backend, :devops keys (from Processor)
      def send_digest(digest_data)
        html_body = render_template(digest_data)
        subject = build_subject

        from_addr = config.email_from.to_s.strip
        to_addrs = parse_email_list(config.email_to)
        raise ArgumentError, "EMAIL_TO is required and cannot be blank" if to_addrs.empty?
        raise ArgumentError, "EMAIL_FROM is required and cannot be blank" if from_addr.empty?

        bcc_addrs = parse_email_list(config.email_bcc)
        logger.info("Sending digest email to #{to_addrs.join(', ')}#{bcc_addrs.any? ? " bcc #{bcc_addrs.join(', ')}" : ''}")

        mail = build_mail(html_body, subject, from_addr, to_addrs, bcc_addrs)
        raw_rfc2822 = mail.encoded
        # Mail gem omits Bcc from encoded output by default. Gmail API requires Bcc in the
        # raw payload to deliver; inject the header before the body (first \r\n\r\n).
        if bcc_addrs.any?
          raw_rfc2822 = raw_rfc2822.sub(/\r?\n\r?\n/, "\r\nBcc: #{bcc_addrs.join(', ')}\r\n\r\n")
        end
        raw_rfc2822 = raw_rfc2822.gsub(/\r?\n/, "\r\n") unless raw_rfc2822.include?("\r\n")

        # Pass raw RFC 2822 string; google-apis-gmail_v1 encodes it to base64url automatically
        credentials = Google::Auth::UserRefreshCredentials.new(
          client_id: config.gmail_client_id,
          client_secret: config.gmail_client_secret,
          refresh_token: config.gmail_refresh_token,
          scope: GMAIL_SEND_SCOPE
        )
        credentials.fetch_access_token!

        service = Google::Apis::GmailV1::GmailService.new
        service.authorization = credentials

        message = Google::Apis::GmailV1::Message.new(raw: raw_rfc2822)
        service.send_user_message("me", message)

        logger.info("Digest email sent successfully")
      rescue StandardError => e
        logger.error("Failed to send email: #{e.message}")
        raise
      end

      private

      # Parse EMAIL_TO: comma or semicolon separated, supports multiple addresses
      def parse_email_list(raw)
        raw.to_s.split(/[,;]/).map(&:strip).reject(&:empty?)
      end

      def build_mail(html_body, subject, from_addr, to_addrs, bcc_addrs = [])
        to_value = to_addrs.is_a?(Array) ? to_addrs : [to_addrs].compact
        bcc_value = bcc_addrs.is_a?(Array) && bcc_addrs.any? ? bcc_addrs : nil
        Mail.new do
          from    from_addr
          to      to_value
          bcc     bcc_value if bcc_value
          subject subject

          text_part do
            content_type "text/plain; charset=UTF-8"
            body "Please view this email in HTML format."
          end

          html_part do
            content_type "text/html; charset=UTF-8"
            body html_body
          end
        end
      end

      def render_template(digest_data)
        template = File.read(TEMPLATE_PATH)
        renderer = TemplateRenderer.new(digest_data, config)
        ERB.new(template, trim_mode: "-").result(renderer.get_binding)
      end

      def build_subject
        end_date = Time.now
        start_date = end_date - (config.lookback_days * 24 * 60 * 60)
        week_str = "#{start_date.strftime('%m/%d')}~#{end_date.strftime('%m/%d')}"
        "[Tech Digest] 每週技術新知摘要 #{week_str}"
      end
    end

    # Provides the binding context for ERB template rendering
    class TemplateRenderer
      attr_reader :digest_data

      def initialize(digest_data, config)
        @digest_data = digest_data
        @config = config
      end

      def date_range
        end_date = Time.now
        start_date = end_date - (@config.lookback_days * 24 * 60 * 60)
        "#{start_date.strftime('%Y/%m/%d')} - #{end_date.strftime('%Y/%m/%d')}"
      end

      def total_items
        digest_data.values.sum do |section|
          next 0 unless section.is_a?(Hash)

          releases = section[:release_items]&.size || 0
          others = section[:other_items]&.size || 0
          releases + others > 0 ? releases + others : (section[:items]&.size || 0)
        end
      end

      def importance_label(importance)
        {
          "critical" => "重大",
          "high" => "重要",
          "medium" => "一般",
          "low" => "參考"
        }.fetch(importance, importance)
      end

      # Split summary into structured parts (📌 核心重點 / 🔍 技術細節 / 📊 建議動作)
      # Returns array of [label, content]; if no structure detected, returns [[nil, full_summary]]
      def summary_parts(summary)
        text = summary.to_s.strip
        return [[nil, ""]] if text.empty?

        parts = text.split(/(?=📌|🔍|📊)/).map(&:strip).reject(&:empty?)
        return [[nil, text]] if parts.empty?

        structured = parts.map do |p|
          if p.start_with?("📌")
            ["📌 核心重點", p.sub(/\A📌\s*(?:核心重點[：:]\s*)?/, "").strip]
          elsif p.start_with?("🔍")
            ["🔍 技術細節", p.sub(/\A🔍\s*(?:技術細節[：:]\s*)?/, "").strip]
          elsif p.start_with?("📊")
            ["📊 建議動作", p.sub(/\A📊\s*(?:建議動作[：:]\s*)?/, "").strip]
          end
        end.compact

        structured.any? ? structured : [[nil, text]]
      end

      # Truncate text to max_length, appending "..." if truncated
      def truncate_text(text, max_length = 200)
        return "" if text.nil?

        # Clean up: remove excessive whitespace, newlines
        cleaned = text.gsub(/\s+/, " ").strip
        cleaned.length > max_length ? "#{cleaned[0...max_length]}..." : cleaned
      end

      # Shorten a URL for display (remove protocol, truncate path)
      def shorten_url(url)
        short = url.to_s.sub(%r{\Ahttps?://}, "").sub(%r{/\z}, "")
        short.length > 50 ? "#{short[0...50]}..." : short
      end

      def get_binding
        binding
      end
    end
  end
end
