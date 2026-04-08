# frozen_string_literal: true

require "workos"

# Configure WorkOS SDK for authentication.
# Values are resolved by config/initializers/app_config.rb into config.x.workos.*
WorkOS.configure do |config|
  config.key = Rails.configuration.x.workos.api_key || "test_key"
end

# Validate required config in non-test environments (warn, don't crash).
unless Rails.env.test?
  missing = []
  missing << "WORKOS_API_KEY (or credentials.workos.api_key)" if Rails.configuration.x.workos.api_key.blank?
  missing << "WORKOS_CLIENT_ID (or credentials.workos.client_id)" if Rails.configuration.x.workos.client_id.blank?

  if missing.any?
    Rails.logger.warn "Missing WorkOS config: #{missing.join(', ')}. " \
                      "WorkOS authentication will be unavailable."
  end
end

# DailyWerk-specific WorkOS constants.
module WorkOS
  module DailyWerk
    SESSION_COOKIE_NAME  = "_dw_auth"
    OAUTH_STATE_COOKIE_NAME = "_dw_oauth_state"
    SESSION_COOKIE_MAX_AGE = 30.days.to_i
    PKCE_COOKIE_MAX_AGE    = 600 # 10 minutes
    WS_TICKET_TTL          = 15  # seconds

    # @return [String, nil] the WorkOS client ID
    def self.client_id
      Rails.configuration.x.workos.client_id
    end

    # @return [Boolean] true when WorkOS credentials are configured
    def self.enabled?
      Rails.configuration.x.workos.api_key.present? && Rails.configuration.x.workos.client_id.present?
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
