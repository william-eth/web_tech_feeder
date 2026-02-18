# frozen_string_literal: true

module WebTechFeeder
  module Utils
    # Shared order-preserving parallel map for I/O-bound workloads.
    module ParallelExecutor
      module_function

      def map(items, max_threads:, parallel:, logger: nil)
        return items.map { |item| yield(item) } unless parallel

        worker_count = [[max_threads.to_i, 1].max, items.size].min
        return items.map { |item| yield(item) } if worker_count <= 1 || items.size <= 1

        queue = Queue.new
        items.each_with_index { |item, idx| queue << [idx, item] }
        results = Array.new(items.size)

        workers = Array.new(worker_count) do
          Thread.new do
            loop do
              idx = nil
              item = nil
              begin
                idx, item = queue.pop(true)
                results[idx] = yield(item)
              rescue ThreadError
                break
              rescue StandardError => e
                logger&.warn("parallel worker error: #{e.class}: #{e.message}")
                results[idx] = nil unless idx.nil?
              end
            end
          end
        end

        workers.each(&:join)
        results
      end
    end
  end
end
