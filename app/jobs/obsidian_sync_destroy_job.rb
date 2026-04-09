# frozen_string_literal: true

# Destroys a VaultSyncConfig with proper cleanup.
# Implements two-phase delete: stop process, cleanup XDG dir, destroy record.
# Called from controller destroy action after marking config as "deleting".
class ObsidianSyncDestroyJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  # Prevent concurrent destroy operations for the same config
  good_job_control_concurrency_with(
    perform_limit: 1,
    total_limit: 2,
    key: -> { "obsidian_sync_destroy_#{arguments.first}" }
  )

  # Config record may have been destroyed if this is a retry
  # In that case, we still need to cleanup the XDG directory
  discard_on ActiveRecord::RecordNotFound

  # @param config_id [String]
  # @param workspace_id [String]
  # @param process_pid [Integer, nil] PID to stop (primitive, survives record deletion)
  # @param process_host [String, nil] Host where process runs
  # @param config_base_path [String] Path to XDG config directory for cleanup
  # @return [void]
  def perform(
    config_id,
    workspace_id:,
    process_pid: nil,
    process_host: nil,
    config_base_path: nil
  )
    # Try to find the config (may not exist on retry)
    config = VaultSyncConfig.find_by(id: config_id)

    # Stop the process if we have a PID and we're on the right host
    if process_pid.present? && (process_host.blank? || process_host == Socket.gethostname)
      stop_process(process_pid, config_id)
    end

    # Cleanup the XDG config directory
    if config_base_path.present? && File.directory?(config_base_path)
      cleanup_config_directory(config_base_path, config_id)
    elsif config.present?
      # Fallback: use the manager to cleanup
      manager = ObsidianSyncManager.new(config)
      manager.cleanup_config_directory!
    end

    # Destroy the record if it still exists
    if config.present?
      # Use delete to skip the after_destroy callback (we already cleaned up)
      config.delete
      Rails.logger.info "[ObsidianSyncDestroyJob] Destroyed sync config #{config_id}"
    end
  rescue StandardError => e
    Rails.logger.error "[ObsidianSyncDestroyJob] Destroy failed for #{config_id}: #{e.message}"
    raise
  end

  private

  # @param pid [Integer]
  # @param config_id [String]
  # @return [void]
  def stop_process(pid, config_id)
    begin
      Process.kill("TERM", -Process.getpgid(pid))
      Rails.logger.info "[ObsidianSyncDestroyJob] Sent SIGTERM to process group #{pid}"
    rescue Errno::ESRCH
      Rails.logger.info "[ObsidianSyncDestroyJob] Process #{pid} already stopped"
      return
    end

    # Wait for graceful shutdown
    30.times do
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        Rails.logger.info "[ObsidianSyncDestroyJob] Process #{pid} exited"
        return
      end
      sleep 1
    end

    # Force kill if still running
    begin
      Process.kill("KILL", -Process.getpgid(pid))
      Rails.logger.warn "[ObsidianSyncDestroyJob] Sent SIGKILL to process group #{pid}"
      sleep 2
    rescue Errno::ESRCH
      # Process finally gone
    end
  end

  # @param path [String]
  # @param config_id [String]
  # @return [void]
  def cleanup_config_directory(path, config_id)
    FileUtils.rm_rf(path)
    Rails.logger.info "[ObsidianSyncDestroyJob] Cleaned up config directory for #{config_id}"
  rescue StandardError => e
    Rails.logger.error "[ObsidianSyncDestroyJob] Failed to cleanup config directory: #{e.message}"
  end
end
