# frozen_string_literal: true

# Stops the Obsidian Sync process.
# Uses "stopping" status to preserve PID during shutdown.
class ObsidianSyncStopJob < ApplicationJob
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

    Rails.logger.info "[ObsidianSyncStopJob] Stopping sync for config #{config_id}"

    manager = ObsidianSyncManager.new(config)
    manager.stop!

    Rails.logger.info "[ObsidianSyncStopJob] Sync stopped for config #{config_id}"
  end
end
