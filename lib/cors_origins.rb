# frozen_string_literal: true

# Parses and validates the configured CORS origins.
module CorsOrigins
  LOCALHOST_ORIGIN = "http://localhost:5173"

  module_function

  # @param env [#[]]
  # @param rails_env [#production?]
  # @return [Array<String>]
  def load!(env:, rails_env:)
    origins = env["CORS_ORIGINS"].to_s.split(",").map(&:strip).reject(&:blank?)

    if rails_env.production? && origins.empty?
      raise "CORS_ORIGINS must be configured in production"
    end

    origins.presence || [ LOCALHOST_ORIGIN ]
  end
end
