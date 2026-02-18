# frozen_string_literal: true

require_relative "enrichers"
require_relative "services/digest_pipeline"

module WebTechFeeder
  class << self
    def run
      Services::DigestPipeline.new.run
    end
  end
end
