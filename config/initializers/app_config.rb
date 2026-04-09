# frozen_string_literal: true

# Resolves all application configuration into config.x.* at boot.
# ENV > Rails credentials > default (local environments only, unless force_default)
#
# This initializer must run before any consumer initializers (good_job.rb, ruby_llm.rb, workos.rb).
require "config_resolver"

resolver = ConfigResolver.new

Rails.application.configure do
  # -- WorkOS --
  config.x.workos.api_key        = resolver.resolve?(:workos, :api_key, env: "WORKOS_API_KEY")
  config.x.workos.client_id      = resolver.resolve?(:workos, :client_id, env: "WORKOS_CLIENT_ID")
  config.x.workos.webhook_secret = resolver.resolve?(:workos, :webhook_secret, env: "WORKOS_WEBHOOK_SECRET")

  # -- OpenAI --
  config.x.openai.api_key = resolver.resolve?(:openai, :api_key, env: "OPENAI_API_KEY")

  # -- Stripe --
  config.x.stripe.secret_key      = resolver.resolve?(:stripe, :secret_key, env: "STRIPE_SECRET_KEY")
  config.x.stripe.webhook_secret  = resolver.resolve?(:stripe, :webhook_secret, env: "STRIPE_WEBHOOK_SECRET")
  config.x.stripe.publishable_key = resolver.resolve?(:stripe, :publishable_key, env: "STRIPE_PUBLISHABLE_KEY")

  # -- S3 / Vault Storage --
  config.x.vault_s3.access_key = resolver.resolve(:storage, :access_key,
                                                  env: "AWS_ACCESS_KEY_ID", default: "rustfsadmin")
  config.x.vault_s3.secret_key = resolver.resolve(:storage, :secret_key,
                                                  env: "AWS_SECRET_ACCESS_KEY", default: "rustfsadmin")
  config.x.vault_s3.region = resolver.resolve(:storage, :region,
                                                env: "AWS_REGION", default: "us-east-1", force_default: true)
  config.x.vault_s3.bucket = resolver.resolve(:storage, :bucket,
                                              env: "S3_BUCKET", default: "dailywerk-dev")
  config.x.vault_s3.endpoint = resolver.resolve?(:storage, :endpoint, env: "AWS_ENDPOINT")
  config.x.vault_s3.force_path_style = resolver.resolve(:storage, :force_path_style,
                                                        env: "AWS_FORCE_PATH_STYLE", default: "true",
                                                        type: :boolean, force_default: true)
  config.x.vault_s3.require_https_for_sse_cpk = resolver.resolve(:storage, :require_https_for_sse_cpk,
                                                                 env: "S3_REQUIRE_HTTPS_FOR_SSE_CPK",
                                                                 default: Rails.env.local? ? "false" : "true",
                                                                 force_default: true, type: :boolean)
  config.x.vault_s3.local_base = ENV.fetch("VAULT_LOCAL_BASE") {
    Rails.env.local? ? Rails.root.join("tmp/workspaces").to_s : "/data/workspaces"
  }

  # Alias for Vault model (reads from config.x.vault_local_base)
  config.x.vault_local_base = config.x.vault_s3.local_base

  # -- Obsidian Sync --
  config.x.obsidian_headless_bin = ENV.fetch("OBSIDIAN_HEADLESS_BIN", "ob")

  # -- GoodJob Auth --
  config.x.good_job.basic_auth_username = resolver.resolve?(:good_job, :basic_auth_username,
                                                           env: "GOOD_JOB_BASIC_AUTH_USERNAME")
  config.x.good_job.basic_auth_password = resolver.resolve?(:good_job, :basic_auth_password,
                                                           env: "GOOD_JOB_BASIC_AUTH_PASSWORD")

  # -- Metrics Auth --
  config.x.metrics.enabled = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("METRICS_ENABLED", "false")
  )
  config.x.metrics.basic_auth_username = resolver.resolve?(:metrics, :basic_auth_username,
                                                           env: "METRICS_BASIC_AUTH_USERNAME")
  config.x.metrics.basic_auth_password = resolver.resolve?(:metrics, :basic_auth_password,
                                                           env: "METRICS_BASIC_AUTH_PASSWORD")

  # -- Deploy --
  config.x.deploy.webhook_secret = resolver.resolve?(:deploy, :webhook_secret,
                                                     env: "DEPLOY_WEBHOOK_SECRET")
end
