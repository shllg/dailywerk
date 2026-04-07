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
          build_sha: ENV["BUILD_SHA"]
        }
      end
    end
  end
end
