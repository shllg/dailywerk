# frozen_string_literal: true

# Performs initial Obsidian Sync setup: login, verify, connect, first sync.
# Then triggers structure analysis and full reindex.
class ObsidianSyncSetupJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param config_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(config_id, workspace_id:)
    config = VaultSyncConfig.find(config_id)
    vault = config.vault

    Rails.logger.info "[ObsidianSyncSetupJob] Starting setup for vault #{vault.id}"

    # Run the setup process
    manager = ObsidianSyncManager.new(config)
    manager.setup!

    # After successful setup, start continuous sync
    manager.start!

    # Generate vault guide from real folder structure
    VaultManager.new(workspace: vault.workspace).analyze_and_guide(vault)

    # Trigger full reindex of all files
    VaultFullReindexJob.perform_later(vault.id, workspace_id: vault.workspace_id)

    Rails.logger.info "[ObsidianSyncSetupJob] Setup completed for vault #{vault.id}"
  rescue ObsidianSyncManager::SyncError => e
    Rails.logger.error "[ObsidianSyncSetupJob] Setup failed for vault #{vault.id}: #{e.message}"
    # Status already updated by manager
    raise
  end
end
