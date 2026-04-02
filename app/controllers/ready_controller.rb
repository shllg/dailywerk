# frozen_string_literal: true

# Exposes a readiness probe for slot cutovers and health automation.
class ReadyController < ActionController::API
  # @return [void]
  def show
    result = Operations::ReadinessCheck.new.call

    render(
      json: {
        status: result.ready? ? "ok" : "error",
        timestamp: Time.current.iso8601,
        build_sha: ENV["BUILD_SHA"],
        build_ref: ENV["BUILD_REF"],
        checks: result.checks
      },
      status: result.ready? ? :ok : :service_unavailable
    )
  end
end
