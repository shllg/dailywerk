# frozen_string_literal: true

# Starts the continuous Obsidian Sync process.
# @deprecated Use ObsidianSyncPeriodicJob for periodic one-shot sync instead.
class ObsidianSyncStartJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  # Prevent concurrent start/stop operations for the same config
  good_job_control_concurrency_with(
    perform_limit: 1,
    total_limit: 2,
    key: -> { "obsidian_sync_lifecycle_#{arguments.first}" }
  )

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
