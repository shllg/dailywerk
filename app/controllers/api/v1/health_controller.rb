# frozen_string_literal: true

module Api
  module V1
    # Reports a minimal API health payload.
    class HealthController < ApplicationController
      skip_authentication!

      # @return [void]
      def show
        render json: {
          status: "ok",
          timestamp: Time.current.iso8601,
          version: Rails.version,
          ruby: RUBY_VERSION,
          build_sha: ENV["BUILD_SHA"],
          build_ref: ENV["BUILD_REF"]
        }
      end
    end
  end
end
