# frozen_string_literal: true

# Stops the Obsidian Sync process.
class ObsidianSyncStopJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :default

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
