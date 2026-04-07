require_relative "boot"
require_relative "../lib/metrics/request_middleware"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

RubyLLM.configure do |config|
  config.use_new_acts_as = true
end

module Dailywerk
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    config.api_only = true
    config.middleware.use ActionDispatch::Cookies
    config.active_record.schema_format = :sql
    config.active_record.encryption.primary_key = (
      ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"] ||
      Rails.application.credentials.dig(:active_record_encryption, :primary_key) ||
      (Rails.env.development? || Rails.env.test? ? "d" * 32 : nil)
    )
    config.active_record.encryption.deterministic_key = (
      ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"] ||
      Rails.application.credentials.dig(:active_record_encryption, :deterministic_key) ||
      (Rails.env.development? || Rails.env.test? ? "e" * 32 : nil)
    )
    config.active_record.encryption.key_derivation_salt = (
      ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"] ||
      Rails.application.credentials.dig(:active_record_encryption, :key_derivation_salt) ||
      (Rails.env.development? || Rails.env.test? ? "f" * 32 : nil)
    )

    # Background jobs
    config.active_job.queue_adapter = :good_job
    config.active_job.queue_name_prefix = ENV.fetch("GOOD_JOB_QUEUE_PREFIX") { "" }
    config.good_job.execution_mode = :external
    config.good_job.enable_cron = ActiveModel::Type::Boolean.new.cast(ENV.fetch("GOOD_JOB_ENABLE_CRON") { "true" })

    config.middleware.insert_before Rails::Rack::Logger, Metrics::RequestMiddleware
  end
end
