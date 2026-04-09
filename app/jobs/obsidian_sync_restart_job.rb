# frozen_string_literal: true

# Restarts the Obsidian Sync process with failure tracking.
class ObsidianSyncRestartJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  # Prevent concurrent restart operations for the same config
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

    Rails.logger.info "[ObsidianSyncRestartJob] Restarting sync for config #{config_id} " \
                      "(failure #{config.consecutive_failures})"

    manager = ObsidianSyncManager.new(config)
    manager.restart!

    Rails.logger.info "[ObsidianSyncRestartJob] Restart completed for config #{config_id}"
  rescue ObsidianSyncManager::SyncError => e
    Rails.logger.error "[ObsidianSyncRestartJob] Restart failed for config #{config_id}: #{e.message}"
    # Failure will be tracked on next health check
    raise
  end
end
