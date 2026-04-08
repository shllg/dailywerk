# frozen_string_literal: true

# Validates production-only configuration that must fail closed at boot.
module ProductionEnvValidator
  BOOLEAN = ActiveModel::Type::Boolean.new

  module_function

  # @param env [#[], #fetch]
  # @param rails_env [#production?]
  # @param config [ActiveSupport::OrderedOptions] Rails configuration (optional, defaults to Rails.configuration)
  # @return [void]
  def validate!(env:, rails_env:, config: Rails.configuration)
    return unless rails_env.production?

    missing = required_config(env:, config:)
    return if missing.empty?

    raise "Missing required production env vars: #{missing.join(', ')}"
  end

  # @param env [#[], #fetch]
  # @param config [ActiveSupport::OrderedOptions]
  # @return [Array<String>]
  def required_config(env:, config:)
    missing = []

    # CORS_ORIGINS stays in ENV (not a secret, infrastructure config)
    missing << "CORS_ORIGINS" if cors_origins(env).empty?

    # GOOD_JOB auth (resolved by app_config.rb from credentials or ENV)
    missing << "GOOD_JOB_BASIC_AUTH_USERNAME" if config.x.good_job.basic_auth_username.blank?
    missing << "GOOD_JOB_BASIC_AUTH_PASSWORD" if config.x.good_job.basic_auth_password.blank?

    # METRICS auth (resolved by app_config.rb from credentials or ENV)
    if config.x.metrics.enabled
      missing << "METRICS_BASIC_AUTH_USERNAME" if config.x.metrics.basic_auth_username.blank?
      missing << "METRICS_BASIC_AUTH_PASSWORD" if config.x.metrics.basic_auth_password.blank?
    end

    missing
  end

  # @param env [#[]]
  # @return [Array<String>]
  def cors_origins(env)
    env["CORS_ORIGINS"].to_s.split(",").map(&:strip).reject(&:blank?)
  end
  private_class_method :cors_origins
end
