# frozen_string_literal: true

module WebTechFeeder
  module Utils
    # Shared text truncation utility used by collectors/enrichers/processors.
    module TextTruncator
      module_function

      def truncate(text, max_length:)
        normalized = text.to_s
        return normalized if normalized.length <= max_length

        "#{normalized[0...max_length]}..."
      end
    end
  end
end
