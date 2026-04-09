# frozen_string_literal: true

module Api
  module V1
    # Serializes vault payloads for API responses.
    class VaultSerializer
      class << self
        # @param vault [Vault]
        # @return [Hash]
        def summary(vault)
          {
            id: vault.id,
            name: vault.name,
            slug: vault.slug,
            vault_type: vault.vault_type,
            status: vault.status,
            file_count: vault.file_count,
            current_size_bytes: vault.current_size_bytes,
            max_size_bytes: vault.max_size_bytes,
            created_at: vault.created_at.iso8601,
            updated_at: vault.updated_at.iso8601
          }
        end

        # @param vault [Vault]
        # @return [Hash]
        def full(vault)
          summary(vault).merge(
            recent_files: vault.vault_files.order(updated_at: :desc).limit(20).map do |file|
              VaultFileSerializer.summary(file)
            end,
            sync_config: vault.sync_config && VaultSyncConfigSerializer.summary(vault.sync_config)
          )
        end
      end
    end
  end
end
