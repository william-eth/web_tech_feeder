# frozen_string_literal: true

module WebTechFeeder
  # Applies section-aware file path filtering using regex patterns from config.
  module SectionFileFilter
    module_function

    def apply(files, patterns)
      return files if files.empty? || patterns.nil? || patterns.empty?

      regexes = patterns.map do |pattern|
        Regexp.new(pattern.to_s, Regexp::IGNORECASE)
      rescue RegexpError
        nil
      end.compact
      return files if regexes.empty?

      filtered = files.select do |f|
        path = f["filename"].to_s
        regexes.any? { |rx| path.match?(rx) }
      end
      filtered.any? ? filtered : files
    end
  end
end
