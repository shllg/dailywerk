# frozen_string_literal: true

require "workos"

# Configure WorkOS SDK for authentication.
WorkOS.configure do |config|
  config.key = ENV.fetch("WORKOS_API_KEY") do
    Rails.logger.warn "WORKOS_API_KEY not set — WorkOS authentication disabled"
    "test_key" if Rails.env.test?
  end
end

# Validate required env vars in non-test environments (warn, don't crash).
unless Rails.env.test?
  missing = %w[WORKOS_API_KEY WORKOS_CLIENT_ID].reject { |var| ENV[var].present? }
  if missing.any?
    Rails.logger.warn "Missing WorkOS env vars: #{missing.join(', ')}. " \
                      "WorkOS authentication will be unavailable."
  end
end

# DailyWerk-specific WorkOS constants.
module WorkOS
  module DailyWerk
    SESSION_COOKIE_NAME  = "_dw_auth"
    PKCE_COOKIE_NAME     = "_dw_pkce"
    SESSION_COOKIE_MAX_AGE = 30.days.to_i
    PKCE_COOKIE_MAX_AGE    = 600 # 10 minutes
    WS_TICKET_TTL          = 15  # seconds

    # @return [String, nil] the WorkOS client ID
    def self.client_id
      ENV["WORKOS_CLIENT_ID"]
    end

    # @return [Boolean] true when WorkOS credentials are configured
    def self.enabled?
      ENV["WORKOS_API_KEY"].present? && ENV["WORKOS_CLIENT_ID"].present?
    end
  end
end

# Eager-load JWKS at boot so the first authenticated request is fast.
# Skipped in test (no real WorkOS connection) and when WorkOS is not configured.
Rails.application.config.after_initialize do
  if WorkOS::DailyWerk.enabled? && !Rails.env.test?
    WorkosJwksService.warm_cache
  end
end
