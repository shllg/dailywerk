# frozen_string_literal: true

# Re-indexes all files in a vault after initial Obsidian Sync import.
class VaultFullReindexJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param vault_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(vault_id, workspace_id:)
    vault = Vault.find(vault_id)

    Rails.logger.info "[VaultFullReindexJob] Starting full reindex for vault #{vault_id}"

    # Get all files in the vault
    file_service = VaultFileService.new(vault: vault)
    paths = file_service.list

    Rails.logger.info "[VaultFullReindexJob] Found #{paths.size} files to index"

    # Enqueue a job for each file
    paths.each do |path|
      VaultFileChangedJob.perform_later(vault.id, path, "create", workspace_id: vault.workspace_id)
    end

    Rails.logger.info "[VaultFullReindexJob] Enqueued #{paths.size} indexing jobs for vault #{vault_id}"
  end
end
