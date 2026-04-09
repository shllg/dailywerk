# frozen_string_literal: true

# Periodic sync job for Obsidian vaults.
# Runs one-shot `ob sync --path` on a schedule via GoodJob cron.
# Replaces the continuous process model (--continuous) with simpler periodic execution.
class ObsidianSyncPeriodicJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  # Prevent concurrent syncs for the same vault
  # This ensures we don't overlap syncs if one takes longer than the interval
  good_job_control_concurrency_with(
    perform_limit: 1,
    total_limit: 2,
    key: -> { "obsidian_sync_periodic_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # Backoff delays for retry attempts (seconds)
  RETRY_DELAYS = [ 5, 10, 30, 60, 300 ].freeze
  MAX_RETRIES = 5

  # @param config_id [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(config_id, workspace_id:)
    config = VaultSyncConfig.find(config_id)

    # Skip if config is in a state that shouldn't sync
    return unless should_sync?(config)

    Rails.logger.info "[ObsidianSyncPeriodicJob] Starting periodic sync for config #{config_id}"

    # Update status to syncing
    config.update!(process_status: "syncing", last_sync_at: Time.current)

    # Run the sync
    manager = ObsidianSyncManager.new(config)
    manager.sync!

    # Sync succeeded - reset failures and update status
    config.update!(
      process_status: "stopped",
      error_message: nil,
      consecutive_failures: 0
    )

    Rails.logger.info "[ObsidianSyncPeriodicJob] Periodic sync completed for config #{config_id}"
  rescue ObsidianSyncManager::SyncError => e
    handle_sync_error(config, e)
    raise
  end

  private

  # @param config [VaultSyncConfig]
  # @return [Boolean]
  def should_sync?(config)
    # Only sync if we're in a valid state
    return false unless config.process_status.in?(%w[stopped error])
    return false if config.sync_type != "obsidian"
    return false if config.obsidian_email.blank? || config.obsidian_password.blank?

    true
  end

  # @param config [VaultSyncConfig]
  # @param error [ObsidianSyncManager::SyncError]
  # @return [void]
  def handle_sync_error(config, error)
    new_failure_count = config.consecutive_failures + 1

    # Check if this is an auth error
    if error.message.match?(/authentication|unauthorized|token|login|401|403/i)
      config.update!(
        process_status: "auth_required",
        error_message: "Authentication failed: #{error.message}",
        consecutive_failures: 0,
        process_pid: nil
      )

      Rails.logger.error "[ObsidianSyncPeriodicJob] Auth failure for config #{config.id}. " \
                         "User must re-authenticate."
      return
    end

    # Check for permanent failure
    if new_failure_count >= MAX_RETRIES
      config.update!(
        process_status: "error",
        error_message: "Sync failed permanently after #{new_failure_count} attempts: #{error.message}",
        consecutive_failures: new_failure_count,
        process_pid: nil
      )

      Rails.logger.error "[ObsidianSyncPeriodicJob] Permanent sync failure for config #{config.id}"
      return
    end

    # Update failure count and schedule retry
    config.update!(
      process_status: "error",
      error_message: "Sync failed (attempt #{new_failure_count}/#{MAX_RETRIES}): #{error.message}",
      consecutive_failures: new_failure_count
    )

    delay = RETRY_DELAYS[new_failure_count - 1] || RETRY_DELAYS.last
    Rails.logger.warn "[ObsidianSyncPeriodicJob] Sync failed for config #{config.id}, " \
                      "retrying in #{delay}s (failure #{new_failure_count})"
  end
end
