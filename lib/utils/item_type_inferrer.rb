# frozen_string_literal: true

module WebTechFeeder
  module Utils
    # Provides a single source of truth for digest item type inference.
    module ItemTypeInferrer
      module_function

      def infer(item)
        title = extract_value(item, :title).downcase
        source = extract_value(item, :source_name, :source).downcase

        return "release" if title.include?("released") || title.include?("release") || source.include?("/releases/")
        return "advisory" if source.include?("advisory") || title.include?("cve") || title.include?("security")
        return "issue" if source.include?("issue") || source.include?("pr")

        "other"
      end

      def extract_value(item, *keys)
        if item.is_a?(Hash)
          keys.each do |key|
            return item[key].to_s if item.key?(key)
            str_key = key.to_s
            return item[str_key].to_s if item.key?(str_key)
          end
          return ""
        end

        keys.each do |key|
          return item.public_send(key).to_s if item.respond_to?(key)
        end
        ""
      end
      private_class_method :extract_value
    end
  end
end
