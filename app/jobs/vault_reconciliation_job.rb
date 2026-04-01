# frozen_string_literal: true

require "digest"

# Compares local vault files against database metadata and repairs drift.
class VaultReconciliationJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    Current.without_workspace_scoping do
      Vault.active.find_each do |vault|
        reconcile_vault(vault)
      rescue StandardError => error
        Rails.logger.error("[VaultReconciliation] Failed for vault #{vault.id}: #{error.message}")
      end
    end
  end

  private

  # @param vault [Vault]
  # @return [void]
  def reconcile_vault(vault)
    return unless Dir.exist?(vault.local_path)

    file_service = VaultFileService.new(vault:)
    local_paths = file_service.list
    db_files = vault.vault_files.pluck(:path)

    (local_paths - db_files).each do |path|
      VaultFileChangedJob.perform_later(vault.id, path, "create", workspace_id: vault.workspace_id)
    end

    (db_files - local_paths).each do |path|
      VaultFileChangedJob.perform_later(vault.id, path, "delete", workspace_id: vault.workspace_id)
    end

    vault.vault_files.where(path: local_paths & db_files).find_each do |vault_file|
      local_path = file_service.resolve_safe_path(vault_file.path)
      next unless File.exist?(local_path)

      disk_hash = Digest::SHA256.file(local_path).hexdigest
      next if vault_file.content_hash == disk_hash

      VaultFileChangedJob.perform_later(vault.id, vault_file.path, "modify", workspace_id: vault.workspace_id)
    end
  end
end
