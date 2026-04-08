# frozen_string_literal: true

module Api
  module V1
    # Serializes vault sync config payloads for API responses.
    # NEVER serializes actual credential values — only boolean presence indicators.
    class VaultSyncConfigSerializer
      class << self
        # @param config [VaultSyncConfig]
        # @return [Hash]
        def summary(config)
          {
            sync_type: config.sync_type,
            sync_mode: config.sync_mode,
            obsidian_vault_name: config.obsidian_vault_name,
            device_name: config.device_name,
            process_status: config.process_status,
            last_sync_at: config.last_sync_at&.iso8601,
            last_health_check_at: config.last_health_check_at&.iso8601,
            consecutive_failures: config.consecutive_failures,
            error_message: config.error_message,
            has_email: config.obsidian_email_enc.present?,
            has_password: config.obsidian_password_enc.present?,
            has_encryption_password: config.obsidian_encryption_password_enc.present?
          }
        end
      end
    end
  end
end
