# frozen_string_literal: true

# Validates production-only env vars that must fail closed at boot.
module ProductionEnvValidator
  BOOLEAN = ActiveModel::Type::Boolean.new

  module_function

  # @param env [#[], #fetch]
  # @param rails_env [#production?]
  # @return [void]
  def validate!(env:, rails_env:)
    return unless rails_env.production?

    missing = required_vars(env:)
    return if missing.empty?

    raise "Missing required production env vars: #{missing.join(', ')}"
  end

  # @param env [#[], #fetch]
  # @return [Array<String>]
  def required_vars(env:)
    missing = []
    missing << "CORS_ORIGINS" if cors_origins(env).empty?
    missing.concat(blank_vars(env, %w[GOOD_JOB_BASIC_AUTH_USERNAME GOOD_JOB_BASIC_AUTH_PASSWORD]))

    if BOOLEAN.cast(env.fetch("METRICS_ENABLED", "false"))
      missing.concat(blank_vars(env, %w[METRICS_BASIC_AUTH_USERNAME METRICS_BASIC_AUTH_PASSWORD]))
    end

    missing
  end

  # @param env [#[]]
  # @return [Array<String>]
  def cors_origins(env)
    env["CORS_ORIGINS"].to_s.split(",").map(&:strip).reject(&:blank?)
  end
  private_class_method :cors_origins

  # @param env [#[]]
  # @param vars [Array<String>]
  # @return [Array<String>]
  def blank_vars(env, vars)
    vars.reject { |var| env[var].present? }
  end
  private_class_method :blank_vars
end
