# frozen_string_literal: true

# Performs initial Obsidian Sync setup: login, verify, connect, first sync.
# Then triggers structure analysis and full reindex.
# Supports MFA via one-time TOTP code passed from controller.
class ObsidianSyncSetupJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  # Prevent concurrent setup for the same config
  good_job_control_concurrency_with(
    perform_limit: 1,
    total_limit: 2,
    key: -> { "obsidian_sync_setup_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # @param config_id [String]
  # @param workspace_id [String]
  # @param mfa_code [String, nil] Optional MFA TOTP code (NOT persisted)
  # @return [void]
  def perform(config_id, workspace_id:, mfa_code: nil)
    config = VaultSyncConfig.find(config_id)
    vault = config.vault

    Rails.logger.info "[ObsidianSyncSetupJob] Starting setup for vault #{vault.id}"

    # Run the setup process (with optional MFA)
    manager = ObsidianSyncManager.new(config)
    manager.setup!(mfa_code: mfa_code)

    # After successful setup, start continuous sync (deprecated - now uses periodic)
    # manager.start!

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
