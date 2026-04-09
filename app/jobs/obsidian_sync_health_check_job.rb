# frozen_string_literal: true

# Cron job: checks health of all running obsidian sync processes and restarts crashed ones.
# Also detects auth failures and transitions to "auth_required" status.
# Runs every minute via GoodJob cron.
class ObsidianSyncHealthCheckJob < ApplicationJob
  # Cross-workspace job - scans all sync configs

  queue_as :default

  # Backoff delays for restart attempts (seconds)
  BACKOFF_DELAYS = [ 5, 10, 30, 60, 300 ].freeze

  # Auth error patterns to detect from stderr logs
  AUTH_ERROR_PATTERNS = [
    /unauthorized/i,
    /authentication failed/i,
    /invalid token/i,
    /token expired/i,
    /401/,
    /403/,
    /login required/i,
    /auth.*fail/i
  ].freeze

  # @return [void]
  def perform
    Rails.logger.info "[ObsidianSyncHealthCheckJob] Starting health check"

    # Scan all running/starting/stopping sync configs across workspaces
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
      if config.consecutive_failures > 0
        config.update!(
          last_health_check_at: Time.current,
          consecutive_failures: 0,
          error_message: nil,
          process_status: "running"
        )
      end

      return
    end

    # Process is not healthy - check for auth errors first
    if auth_error_detected?(config)
      handle_auth_failure(config)
      return
    end

    # Regular process failure
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

  # @param config [VaultSyncConfig]
  # @return [Boolean]
  def auth_error_detected?(config)
    # Check stderr log for auth error patterns
    stderr_log = Rails.root.join("log", "obsidian", "#{config.vault_id}_stderr.log")
    return false unless File.exist?(stderr_log)

    # Read last 50 lines of stderr
    stderr_content = File.readlines(stderr_log).last(50).join
    return false if stderr_content.blank?

    AUTH_ERROR_PATTERNS.any? { |pattern| stderr_content.match?(pattern) }
  rescue StandardError => e
    Rails.logger.error "[ObsidianSyncHealthCheckJob] Error reading stderr log: #{e.message}"
    false
  end

  # @param config [VaultSyncConfig]
  # @return [void]
  def handle_auth_failure(config)
    config.update!(
      process_status: "auth_required",
      error_message: "Authentication failed. Please re-authenticate.",
      last_health_check_at: Time.current,
      consecutive_failures: 0,
      process_pid: nil
    )

    # Stop any lingering process
    manager = ObsidianSyncManager.new(config)
    manager.stop!

    Rails.logger.error "[ObsidianSyncHealthCheckJob] Auth failure detected for vault #{config.vault_id}. " \
                       "Transitioned to auth_required status."
  end
end
