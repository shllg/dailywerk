# frozen_string_literal: true

# Cron job: checks health of all running obsidian sync processes and restarts crashed ones.
# Runs every minute via GoodJob cron.
class ObsidianSyncHealthCheckJob < ApplicationJob
  # Cross-workspace job - scans all sync configs

  queue_as :default

  # Backoff delays for restart attempts (seconds)
  BACKOFF_DELAYS = [ 5, 10, 30, 60, 300 ].freeze

  # @return [void]
  def perform
    Rails.logger.info "[ObsidianSyncHealthCheckJob] Starting health check"

    # Scan all running/starting sync configs across workspaces
    Current.without_workspace_scoping do
      VaultSyncConfig.needing_health_check.find_each do |config|
        check_and_recover(config)
      end
    end

    Rails.logger.info "[ObsidianSyncHealthCheckJob] Health check completed"
  end

  private

  # @param config [VaultSyncConfig]
  # @return [void]
  def check_and_recover(config)
    manager = ObsidianSyncManager.new(config)

    # Check if process is healthy
    if manager.healthy?
      # Healthy - reset failure count and update last check
      config.update!(
        last_health_check_at: Time.current,
        consecutive_failures: 0,
        error_message: nil
      ) if config.consecutive_failures > 0

      return
    end

    # Process is not healthy
    new_failure_count = config.consecutive_failures + 1

    Rails.logger.warn "[ObsidianSyncHealthCheckJob] Unhealthy sync detected for vault #{config.vault_id} " \
                      "(failure #{new_failure_count}/#{VaultSyncConfig::MAX_FAILURES})"

    # Check if permanently failed
    if new_failure_count >= VaultSyncConfig::MAX_FAILURES
      config.update!(
        process_status: "error",
        error_message: "Process failed permanently after #{new_failure_count} attempts",
        last_health_check_at: Time.current,
        consecutive_failures: new_failure_count
      )

      # Stop any lingering process
      manager.stop!

      Rails.logger.error "[ObsidianSyncHealthCheckJob] Sync permanently failed for vault #{config.vault_id}"
      return
    end

    # Update failure count
    config.update!(
      last_health_check_at: Time.current,
      consecutive_failures: new_failure_count
    )

    # Schedule restart with exponential backoff
    delay = BACKOFF_DELAYS[new_failure_count - 1] || BACKOFF_DELAYS.last
    ObsidianSyncRestartJob.set(wait: delay.seconds).perform_later(
      config.id,
      workspace_id: config.workspace_id
    )

    Rails.logger.info "[ObsidianSyncHealthCheckJob] Scheduled restart for vault #{config.vault_id} in #{delay}s"
  end
end
