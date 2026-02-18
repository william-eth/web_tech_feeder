# frozen_string_literal: true

module WebTechFeeder
  module Utils
    # Builds optional log context tags for correlation/thread tracing.
    module LogContext
      module_function

      def tag(run_id:, show_cid:, show_thread:)
        tags = []
        rid = run_id.to_s.strip
        tags << "[cid=#{rid}]" if show_cid && !rid.empty?
        tags << "[tid=#{Thread.current.object_id.to_s(16)}]" if show_thread
        tags.empty? ? "" : "#{tags.join(' ')} "
      end
    end
  end
end
