# frozen_string_literal: true

# Cron job: enqueues periodic sync jobs for all configured Obsidian vaults.
# Runs every 5 minutes via GoodJob cron.
# Scans all vaults with obsidian sync configs and enqueues individual sync jobs.
class ObsidianSyncPeriodicAllJob < ApplicationJob
  # Cross-workspace job - scans all sync configs

  queue_as :default

  # @return [void]
  def perform
    Rails.logger.info "[ObsidianSyncPeriodicAllJob] Starting periodic sync scan"

    count = 0

    # Scan all vaults with obsidian sync configs that are available for sync
    Current.without_workspace_scoping do
      VaultSyncConfig.available_for_sync
        .where(sync_type: "obsidian")
        .where.not(obsidian_email_enc: nil)
        .where.not(obsidian_password_enc: nil)
        .find_each do |config|
          enqueue_sync(config)
          count += 1
        end
    end

    Rails.logger.info "[ObsidianSyncPeriodicAllJob] Enqueued #{count} periodic sync jobs"
  end

  private

  # @param config [VaultSyncConfig]
  # @return [void]
  def enqueue_sync(config)
    ObsidianSyncPeriodicJob.perform_later(
      config.id,
      workspace_id: config.workspace_id
    )
  rescue StandardError => e
    Rails.logger.error "[ObsidianSyncPeriodicAllJob] Failed to enqueue sync for #{config.id}: #{e.message}"
  end
end
