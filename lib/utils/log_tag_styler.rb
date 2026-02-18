# frozen_string_literal: true

module WebTechFeeder
  module Utils
    # Styles bracket log tags with ANSI colors for better scanability.
    module LogTagStyler
      module_function

      def style(tag)
        name = tag.to_s
        color = color_for(name)
        "\e[#{color}m[#{name}]\e[0m"
      end

      def color_for(tag)
        down = tag.downcase
        return 94 if down.include?("pr-files")
        return 95 if down.include?("linked-refs") || down.include?("linked-pr")
        return 96 if down.include?("pr-compare") || down.include?("compare")
        return 93 if down.include?("cache-hit")

        97
      end
      private_class_method :color_for
    end
  end
end
