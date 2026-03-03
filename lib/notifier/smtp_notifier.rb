# frozen_string_literal: true

require "cgi"
require "mail"
require "erb"
require "google/apis/gmail_v1"
require "googleauth"
require "strscan"

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
        "【Tech Digest】 每週技術新知摘要 #{week_str}"
      end
    end

    # Provides the binding context for ERB template rendering
    class TemplateRenderer
      attr_reader :digest_data

      def initialize(digest_data, config)
        @digest_data = digest_data
        @config = config
      end

      def project_version
        v = @config.respond_to?(:project_version) ? @config.project_version : nil
        s = v.to_s.strip
        s.empty? || s.downcase == "unknown" ? nil : s
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
            ["📌 核心重點", normalize_block_content(p, icon: "📌", heading: "核心重點")]
          elsif p.start_with?("🔍")
            ["🔍 技術細節", normalize_block_content(p, icon: "🔍", heading: "技術細節")]
          elsif p.start_with?("📊")
            ["📊 建議動作", normalize_block_content(p, icon: "📊", heading: "建議動作")]
          end
        end.compact

        structured.any? ? structured : [[nil, text]]
      end

      # Remove duplicated heading text from block content, e.g.
      # "📌 核心重點 核心重點：..." => "..."
      def normalize_block_content(text, icon:, heading:)
        content = text.to_s.sub(/\A#{Regexp.escape(icon)}\s*/, "")
        2.times do
          content = content.sub(/\A#{Regexp.escape(heading)}(?:\s*[：:])?\s*/i, "")
        end
        content.strip
      end

      # Truncate text to max_length, appending "..." if truncated.
      # Prefers breaking at last space to avoid mid-word cuts.
      # Avoids cutting in the middle of GitHub-style issue refs: (#12345), #12345.
      def truncate_text(text, max_length = 200)
        return "" if text.nil?

        cleaned = text.to_s.gsub(/\r\n?/, "\n").strip
        return cleaned if cleaned.length <= max_length

        cut = cleaned[0...max_length]
        # If we cut inside (#\d+) or #\d+, extend to include the full ref or trim the partial
        rest = cleaned[max_length..]
        if cut =~ /\(#\d*$/
          if rest && rest.match?(/\A(\d*)\)/)
            cut = "#{cut}#{Regexp.last_match(1)})"
          else
            cut = cut.sub(/\(#\d*$/, "")
          end
        elsif cut =~ /#\d*$/ && rest && rest.match?(/\A(\d+)/)
          cut = "#{cut}#{Regexp.last_match(1)}"
        else
          last_space = cut.rindex(" ")
          cut = cleaned[0...last_space].rstrip if last_space && (max_length - last_space) < 15
        end
        "#{cut}..."
      end

      # Shorten a URL for display (remove protocol, truncate path)
      def shorten_url(url)
        short = url.to_s.sub(%r{\Ahttps?://}, "").sub(%r{/\z}, "")
        short.length > 50 ? "#{short[0...50]}..." : short
      end

      # Escape HTML to prevent injection and layout breakage from <, >, &, "
      def escape_html(str)
        CGI.escapeHTML(str.to_s)
      end

      def github_repo_base_url(url)
        return nil if url.to_s.strip.empty?
        base = url.to_s.strip.sub(%r{/releases/.*}, "").sub(%r{/issues/.*}, "").sub(%r{/pull/.*}, "").sub(%r{/tree/.*}, "").sub(%r{/blob/.*}, "").sub(%r{/\z}, "")
        base.match?(%r{\Ahttps?://github\.com/[^/]+/[^/]+}) ? base : nil
      end

      def linkify_github_refs(html, repo_url)
        base = github_repo_base_url(repo_url)
        return html unless base

        issues_url = "#{base}/issues/"
        link_style = item_title_link_style
        # (#12345) first, then standalone #12345 — use placeholders to avoid double-replace
        html = html.gsub(/\(#(\d+)\)/) { "__PAREN_REF_#{Regexp.last_match(1)}__" }
        html = html.gsub(/(?<![#"\/\w&;])(#(\d+))(?!\d)/) do
          "<a href=\"#{issues_url}#{Regexp.last_match(2)}\" style=\"#{link_style}\">##{Regexp.last_match(2)}</a>"
        end
        html.gsub(/__PAREN_REF_(\d+)__/) { "(<a href=\"#{issues_url}#{Regexp.last_match(1)}\" style=\"#{link_style}\">##{Regexp.last_match(1)}</a>)" }
      end

      # Format summary content: escape HTML, convert ```...``` to block code, `...` to inline code.
      # Optionally linkify GitHub issue refs (#12345, (#12345)) when github_repo_url is given.
      def format_summary_content(text, github_repo_url = nil)
        return "" if text.to_s.strip.empty?

        # Normalize pre-escaped entities from upstream content (e.g. &#39;)
        # before escaping again for safe HTML rendering.
        normalized_text = CGI.unescapeHTML(text.to_s)
        blocks = []
        with_placeholders = normalized_text.gsub(/```([a-zA-Z0-9_+\-]*)\s*\n?(.*?)```/m) do
          lang = normalize_code_lang(Regexp.last_match(1))
          code = Regexp.last_match(2).to_s.strip.gsub(/\r\n?/, "\n")
          idx = blocks.length
          blocks << [lang, code]
          "__CODE_BLOCK_#{idx}__"
        end

        escaped = escape_html(with_placeholders)
        # Preserve paragraph breaks so blocks render with visual separation
        escaped = escaped.gsub(/\r\n?/, "\n").gsub(/\n{2,}/, "<br>").gsub(/\n/, "<br>")

        # Convert Markdown list items (- or *) to bullet points (•)
        escaped = escaped.gsub(/(?:^|<br>)\s*(?:-|\*)\s+/) { |m| m.sub(/[-*]/, '•') }

        escaped = linkify_github_refs(escaped, github_repo_url) if github_repo_url.to_s.strip != ""
        with_inline = escaped.gsub(/`([^`\n]+)`/) do
          "<code class=\"summary-inline-code\" style=\"#{inline_code_style}\">#{Regexp.last_match(1)}</code>"
        end

        with_inline.gsub(/__CODE_BLOCK_(\d+)__/) do
          idx = Regexp.last_match(1).to_i
          lang, code = blocks[idx]
          render_code_block(lang, code)
        end
      end

      def page_body_style
        "margin:0;padding:0;width:100%;font-family:ui-sans-serif,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;" \
          "font-size:14px;line-height:1.6;color:#334155;background-color:#f1f5f9;"
      end

      def wrapper_style
        "max-width:640px;margin:0 auto;padding:16px;"
      end

      def header_style
        "background:#0f172a;color:#e2e8f0;padding:24px 24px;border-radius:6px 6px 0 0;"
      end

      def content_style
        "background:#ffffff;padding:0;border-radius:0 0 6px 6px;border:1px solid #e2e8f0;border-top:none;"
      end

      def section_style
        "padding:20px 24px;border-bottom:1px solid #e2e8f0;"
      end

      def section_header_style
        "padding:0 0 16px 0;"
      end

      def section_title_style
        "font-size:15px;font-weight:600;color:#0f172a;margin:0;display:inline;mso-line-height-rule:exactly;"
      end

      def section_count_style
        "font-size:12px;color:#94a3b8;font-family:ui-monospace,monospace;margin-left:8px;"
      end

      def section_tag_style(section_key)
        base = "display:inline-block;font-size:11px;font-family:ui-monospace,monospace;font-weight:600;" \
               "padding:3px 8px;border-radius:4px;letter-spacing:0.5px;margin-right:8px;"
        color = case section_key.to_sym
                when :frontend then "background:#dbeafe;color:#1d4ed8;"
                when :backend then "background:#fee2e2;color:#b91c1c;"
                when :devops then "background:#dcfce7;color:#15803d;"
                else "background:#e2e8f0;color:#475569;"
                end
        "#{base}#{color}"
      end

      def subsection_title_style
        "font-size:12px;font-weight:600;color:#64748b;text-transform:uppercase;letter-spacing:0.5px;padding:14px 0 8px 0;mso-line-height-rule:exactly;"
      end

      def item_style(importance)
        base = "padding:14px 16px;border-radius:4px;border:1px solid #e2e8f0;border-left:3px solid #94a3b8;background:#f8fafc;"
        color = case importance.to_s.downcase
                when "critical" then "border-left-color:#dc2626;background:#fef2f2;"
                when "high" then "border-left-color:#ea580c;background:#fff7ed;"
                when "medium" then "border-left-color:#2563eb;background:#eff6ff;"
                else ""
                end
        "#{base}#{color}"
      end

      def item_title_style
        "font-size:14px;font-weight:600;color:#0f172a;margin:0 0 6px 0;line-height:1.4;mso-line-height-rule:exactly;"
      end

      def item_title_link_style
        "color:#0369a1;text-decoration:none;"
      end

      def importance_badge_style(importance)
        base = "display:inline-block;font-size:10px;font-family:ui-monospace,monospace;font-weight:600;padding:2px 6px;" \
               "border-radius:3px;text-transform:uppercase;letter-spacing:0.3px;vertical-align:middle;margin-left:8px;"
        color = case importance.to_s.downcase
                when "critical" then "background:#fecaca;color:#b91c1c;"
                when "high" then "background:#fed7aa;color:#c2410c;"
                when "medium" then "background:#bfdbfe;color:#1d4ed8;"
                else "background:#cbd5e1;color:#475569;"
                end
        "#{base}#{color}"
      end

      def framework_badge_style
        "display:inline-block;font-size:11px;font-family:ui-monospace,monospace;font-weight:500;padding:2px 8px;border-radius:3px;" \
          "background:#e2e8f0;color:#475569;margin-right:8px;vertical-align:middle;"
      end

      def item_summary_style
        "font-size:13px;color:#475569;margin:0 0 8px 0;line-height:1.4;word-break:break-word;overflow-wrap:anywhere;white-space:normal;mso-line-height-rule:exactly;"
      end

      def summary_part_style
        "padding:0 0 16px 0;"
      end

      def summary_part_label_style
        "font-size:13px;font-weight:700;color:#0f172a;margin-bottom:8px;padding-bottom:4px;border-bottom:1px solid #cbd5e1;display:block;mso-line-height-rule:exactly;"
      end

      def summary_part_body_style
        "word-break:break-word;overflow-wrap:anywhere;white-space:normal;line-height:1.5;color:#334155;mso-line-height-rule:exactly;"
      end

      def item_source_style
        "font-size:11px;color:#94a3b8;margin:0;mso-line-height-rule:exactly;"
      end

      def item_source_link_style
        "color:#64748b;text-decoration:none;"
      end

      def item_count_style
        "display:inline-block;font-size:12px;font-family:ui-monospace,monospace;color:#cbd5e1;background:#1e293b;padding:4px 12px;border-radius:4px;margin-top:10px;font-weight:500;"
      end

      def date_range_style
        "font-size:12px;color:#94a3b8;margin:0;mso-line-height-rule:exactly;"
      end

      def header_title_style
        "margin:0 0 6px 0;font-size:18px;font-weight:600;font-family:ui-monospace,'SF Mono','Fira Code','Cascadia Code',monospace;letter-spacing:0.5px;mso-line-height-rule:exactly;"
      end

      def empty_state_style
        "text-align:center;padding:24px;color:#94a3b8;font-size:13px;"
      end

      def footer_style
        "text-align:center;padding:16px;font-size:11px;color:#94a3b8;"
      end

      def footer_link_style
        "color:#64748b;text-decoration:none;"
      end

      def block_code_style(lang = nil)
        palette = code_style_palette(lang)
        "display:block;#{code_font_family}font-size:12px;" \
          "background:#{palette[:bg]};color:#{palette[:fg]};border:1px solid #{palette[:border]};" \
          "border-left:4px solid #{palette[:accent]};border-radius:6px;padding:10px 12px;margin:8px 0;" \
          "line-height:1.5;white-space:pre-wrap;" \
          "word-break:break-word;overflow-wrap:anywhere;"
      end

      def code_font_family
        "font-family:ui-monospace,SFMono-Regular,'SF Mono',Menlo,Consolas,'Liberation Mono',monospace;"
      end

      def inline_code_style
        "#{code_font_family}font-size:0.9em;background:#e2e8f0;color:#334155;padding:2px 6px;border-radius:3px;white-space:normal;word-break:break-word;overflow-wrap:anywhere;"
      end

      def normalize_code_lang(lang)
        raw = lang.to_s.strip.downcase
        return "plain" if raw.empty?
        return "ts" if %w[typescript tsx ts].include?(raw)
        return "js" if %w[javascript jsx js].include?(raw)
        return "shell" if %w[shell sh bash zsh].include?(raw)
        return "yaml" if %w[yaml yml].include?(raw)
        return "ruby" if raw == "rb"

        raw
      end

      def code_style_palette(lang)
        case normalize_code_lang(lang)
        when "ruby"
          { bg: "#111827", fg: "#f9fafb", border: "#374151", accent: "#f59e0b" }
        when "ts", "js"
          { bg: "#0f172a", fg: "#e2e8f0", border: "#334155", accent: "#60a5fa" }
        when "shell"
          { bg: "#0b1320", fg: "#e2e8f0", border: "#334155", accent: "#22d3ee" }
        when "yaml"
          { bg: "#141125", fg: "#e9d5ff", border: "#4c1d95", accent: "#a78bfa" }
        else
          { bg: "#0f172a", fg: "#e2e8f0", border: "#334155", accent: "#64748b" }
        end
      end

      def render_code_block(lang, code)
        highlighted = highlight_code(lang, code)
        "<code class=\"summary-code summary-code-#{lang}\" style=\"#{block_code_style(lang)}\">#{highlighted}</code>"
      end

      def highlight_code(lang, code)
        normalized = normalize_code_lang(lang)
        return escape_html(code.to_s) unless %w[ruby ts js shell yaml].include?(normalized)

        tokens = tokenize_code(code.to_s, normalized)
        tokens.map { |type, text| wrap_token(type, text) }.join
      end

      def wrap_token(type, text)
        style = token_style(type)
        escaped = escape_html(text)
        return escaped if style.nil?

        "<span style=\"#{style}\">#{escaped}</span>"
      end

      def token_style(type)
        case type
        when :comment then "color:#94a3b8;"
        when :string then "color:#86efac;"
        when :number then "color:#fca5a5;"
        when :keyword then "color:#93c5fd;font-weight:600;"
        when :method then "color:#fcd34d;"
        when :constant then "color:#c4b5fd;"
        when :symbol then "color:#f9a8d4;"
        when :variable then "color:#67e8f9;"
        when :yaml_key then "color:#fcd34d;font-weight:600;"
        else nil
        end
      end

      def tokenize_code(code, lang)
        scanner = StringScanner.new(code)
        tokens = []
        patterns = token_patterns(lang)

        until scanner.eos?
          matched = false
          patterns.each do |type, regex|
            chunk = scanner.scan(regex)
            next unless chunk

            tokens << [type, chunk]
            matched = true
            break
          end
          next if matched

          tokens << [nil, scanner.getch]
        end

        tokens
      end

      def token_patterns(lang)
        common = [
          [:string, /"(?:\\.|[^"\\])*"/],
          [:string, /'(?:\\.|[^'\\])*'/],
          [:number, /\b\d+(?:\.\d+)?\b/],
          [:identifier, /[a-zA-Z_]\w*/]
        ]

        case lang
        when "ruby"
          ruby_keywords = /\b(?:def|class|module|if|elsif|else|unless|case|when|while|until|do|end|begin|rescue|ensure|return|yield|super|self|nil|true|false|and|or|not|in)\b/
          [
            [:comment, /#[^\n]*/],
            [:symbol, /:[a-zA-Z_]\w*[!?=]?/],
            [:method, /\.[a-zA-Z_]\w*[!?=]?/],
            [:constant, /\b[A-Z][A-Za-z0-9_]*\b/],
            [:keyword, ruby_keywords]
          ] + common
        when "ts", "js"
          js_keywords = /\b(?:const|let|var|function|return|if|else|switch|case|break|continue|for|while|do|try|catch|finally|throw|new|class|extends|implements|interface|type|import|from|export|default|async|await|null|undefined|true|false|this|typeof|instanceof)\b/
          [
            [:comment, %r{/\*[\s\S]*?\*/}],
            [:comment, %r{//[^\n]*}],
            [:method, /\.[a-zA-Z_$][\w$]*/],
            [:constant, /\b[A-Z][A-Za-z0-9_]*\b/],
            [:keyword, js_keywords]
          ] + common
        when "shell"
          shell_keywords = /\b(?:if|then|else|elif|fi|for|in|do|done|case|esac|while|until|function|select|time|export|local|readonly|unset|return|exit)\b/
          [
            [:comment, /#[^\n]*/],
            [:variable, /\$[A-Za-z_][A-Za-z0-9_]*/],
            [:keyword, shell_keywords]
          ] + common
        when "yaml"
          yaml_keywords = /\b(?:true|false|null|yes|no|on|off)\b/
          [
            [:comment, /#[^\n]*/],
            [:yaml_key, /(?:^|\n)([ \t-]*[A-Za-z0-9_.-]+)(?=:\s|:$)/],
            [:variable, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/],
            [:keyword, yaml_keywords]
          ] + common
        else
          common
        end
      end

      def get_binding
        binding
      end
    end
  end
end
