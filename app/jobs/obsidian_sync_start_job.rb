# frozen_string_literal: true

# Starts the continuous Obsidian Sync process.
class ObsidianSyncStartJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param config_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(config_id, workspace_id:)
    config = VaultSyncConfig.find(config_id)

    Rails.logger.info "[ObsidianSyncStartJob] Starting sync for config #{config_id}"

    manager = ObsidianSyncManager.new(config)
    manager.start!

    Rails.logger.info "[ObsidianSyncStartJob] Sync started for config #{config_id}"
  rescue ObsidianSyncManager::SyncError => e
    Rails.logger.error "[ObsidianSyncStartJob] Start failed for config #{config_id}: #{e.message}"
    raise
  end
end
