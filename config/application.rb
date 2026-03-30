require_relative "boot"

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
    config.active_record.schema_format = :sql

    # Background jobs
    config.active_job.queue_adapter = :good_job
    config.active_job.queue_name_prefix = ENV.fetch("GOOD_JOB_QUEUE_PREFIX") { "" }
    config.good_job.execution_mode = :external
    config.good_job.enable_cron = ActiveModel::Type::Boolean.new.cast(ENV.fetch("GOOD_JOB_ENABLE_CRON") { "true" })

    # GoodJob dashboard needs these middleware in API-only mode
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore, key: "_dailywerk_session"
    config.middleware.use ActionDispatch::Flash
    config.middleware.use Rack::MethodOverride
  end
end
