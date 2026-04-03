require "active_support/core_ext/integer/time"
require_relative "../../lib/structured_log_formatter"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files in Hetzner Object Storage via the S3-compatible adapter.
  config.active_storage.service = :hetzner

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info").to_sym

  if ActiveModel::Type::Boolean.new.cast(ENV.fetch("RAILS_LOG_TO_STDOUT", "true"))
    logger = ActiveSupport::Logger.new($stdout)
    logger.formatter = StructuredLogFormatter.new
    config.logger = logger
  end

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/ready"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # config.active_job.queue_adapter = :resque

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  config.cache_store = :redis_cache_store, {
    url: ENV.fetch("VALKEY_URL"),
    namespace: ENV.fetch("CACHE_NAMESPACE", "dailywerk:prod:cache")
  }

  config.action_cable.url = "wss://#{ENV.fetch("APP_HOST")}/cable"
  config.action_cable.allowed_request_origins = ENV.fetch("ACTION_CABLE_ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:blank?)

  config.x.vault_s3_bucket = ENV["S3_BUCKET"].presence || ENV["VAULT_S3_BUCKET"]
  config.x.vault_s3_endpoint = ENV["AWS_ENDPOINT"].presence || ENV["VAULT_S3_ENDPOINT"]
  config.x.vault_s3_region = ENV["AWS_REGION"].presence || ENV.fetch("VAULT_S3_REGION", "fsn1")
  config.x.vault_s3_require_https_for_sse_cpk = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("S3_REQUIRE_HTTPS_FOR_SSE_CPK") { ENV.fetch("VAULT_S3_REQUIRE_HTTPS_FOR_SSE_CPK", "true") }
  )
  config.x.vault_local_base = ENV.fetch("VAULT_LOCAL_BASE", "/data/workspaces")

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  config.hosts = [ ENV["APP_HOST"] ].compact_blank
  config.host_authorization = {
    exclude: ->(request) { request.path == "/ready" || request.path == "/metrics" }
  }
end
