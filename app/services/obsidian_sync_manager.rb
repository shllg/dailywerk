# frozen_string_literal: true

require "open3"
require "English"

# Manages the obsidian-headless CLI process for vault sync.
# ALL methods use blocking I/O and must ONLY be called from GoodJob workers.
class ObsidianSyncManager
  STOP_TIMEOUT_SECONDS = 30
  PROCESS_CHECK_TIMEOUT = 5

  class SyncError < StandardError; end

  # @param config [VaultSyncConfig]
  def initialize(config)
    @config = config
    @vault = config.vault
    @logger = Rails.logger
  end

  # Performs initial setup: login, verify remote vault, connect, one-shot sync.
  #
  # @return [Boolean] true if setup succeeded
  # @raise [SyncError] if setup fails
  def setup!
    ensure_cli_available!

    # Step 1: Login with credentials
    login!

    # Step 2: Verify the remote vault exists
    verify_vault!

    # Step 3: Connect this device to the vault
    connect!

    # Step 4: One-shot sync to pull initial content
    sync!

    update_status("stopped", error_message: nil, consecutive_failures: 0)
    true
  rescue StandardError => e
    update_status("error", error_message: e.message)
    raise SyncError, "Setup failed: #{e.message}"
  end

  # Starts the continuous sync process (ob sync --continuous).
  # Uses Process.spawn with credential isolation.
  #
  # @return [Boolean] true if process started
  # @raise [SyncError] if start fails
  def start!
    return true if healthy?

    ensure_cli_available!

    # Stop any existing process first
    stop! if @config.process_pid.present?

    # Prepare environment with credentials (isolated from Rails env)
    env = build_credential_env

    # Log files for the process
    log_dir = Rails.root.join("log", "obsidian")
    FileUtils.mkdir_p(log_dir)
    stdout_log = log_dir.join("#{@vault.id}_stdout.log")
    stderr_log = log_dir.join("#{@vault.id}_stderr.log")

    update_status("starting")

    # Spawn the continuous sync process (array form avoids shell injection)
    pid = Process.spawn(
      env,
      [ cli_bin, "sync", "--continuous", "--vault", @config.obsidian_vault_name.to_s ],
      {
        unsetenv_others: true,
        pgroup: true,
        out: stdout_log.to_s,
        err: stderr_log.to_s,
        chdir: @vault.local_path
      }
    )

    # Detach so we don't create a zombie when it exits
    Process.detach(pid)

    update_status("running", process_pid: pid, process_host: Socket.gethostname)

    @logger.info "[ObsidianSync] Started continuous sync for vault #{@vault.id} (PID: #{pid})"

    true
  rescue StandardError => e
    update_status("error", error_message: "Failed to start: #{e.message}")
    raise SyncError, "Start failed: #{e.message}"
  end

  # Stops the sync process gracefully with SIGTERM, then SIGKILL if needed.
  #
  # @return [Boolean] true if stopped (or already stopped)
  def stop!
    pid = @config.process_pid

    if pid.blank?
      update_status("stopped", process_pid: nil)
      return true
    end

    # Check if process is actually running
    unless healthy?
      update_status("stopped", process_pid: nil)
      return true
    end

    update_status("stopped")

    # Try graceful shutdown with SIGTERM
    begin
      Process.kill("TERM", -Process.getpgid(pid)) # Negative PID kills whole process group
      @logger.info "[ObsidianSync] Sent SIGTERM to process group #{pid}"
    rescue Errno::ESRCH
      # Process already gone
      update_status("stopped", process_pid: nil)
      return true
    end

    # Wait for graceful shutdown
    wait_for_exit(pid, STOP_TIMEOUT_SECONDS)

    # If still running, force kill
    if process_alive?(pid)
      begin
        Process.kill("KILL", -Process.getpgid(pid))
        @logger.warn "[ObsidianSync] Sent SIGKILL to process group #{pid}"
      rescue Errno::ESRCH
        # Process finally gone
      end

      # Brief wait for SIGKILL to take effect
      wait_for_exit(pid, 5)
    end

    update_status("stopped", process_pid: nil)

    @logger.info "[ObsidianSync] Stopped sync for vault #{@vault.id}"

    true
  rescue StandardError => e
    @logger.error "[ObsidianSync] Error stopping sync: #{e.message}"
    update_status("error", error_message: "Stop failed: #{e.message}", process_pid: nil)
    false
  end

  # Checks if the sync process is healthy (running and responding).
  #
  # @return [Boolean]
  def healthy?
    pid = @config.process_pid
    return false if pid.blank?

    # Check if we're on the same host (in case of multi-server setup)
    return false if @config.process_host.present? && @config.process_host != Socket.gethostname

    process_alive?(pid)
  end

  # Restarts the sync process (stop + start).
  #
  # @return [Boolean] true if restart succeeded
  def restart!
    stop!
    start!
  end

  private

  # @return [void]
  def ensure_cli_available!
    return if File.executable?(cli_bin)

    raise SyncError, "obsidian-headless CLI not found at #{cli_bin}. Run: npm install -g obsidian-headless"
  end

  # @return [String] path to the obsidian-headless binary
  def cli_bin
    Rails.configuration.x.obsidian_headless_bin.presence || "ob"
  end

  # @return [Hash] environment variables with credentials (isolated)
  def build_credential_env
    env = {
      "OBSIDIAN_EMAIL" => @config.obsidian_email.to_s,
      "OBSIDIAN_PASSWORD" => @config.obsidian_password.to_s
    }

    # Add encryption password if configured
    if @config.obsidian_encryption_password.present?
      env["OBSIDIAN_ENCRYPTION_PASSWORD"] = @config.obsidian_encryption_password.to_s
    end

    env
  end

  # @return [void]
  def login!
    stdout, stderr, status = Open3.capture3(
      build_credential_env,
      [ cli_bin, "login" ],
      unsetenv_others: true,
      chdir: @vault.local_path
    )

    raise SyncError, "Login failed: #{stderr}" unless status.success?

    @logger.info "[ObsidianSync] Logged in successfully for vault #{@vault.id}"
  end

  # @return [void]
  def verify_vault!
    stdout, stderr, status = Open3.capture3(
      build_credential_env,
      [ cli_bin, "vaults" ],
      unsetenv_others: true,
      chdir: @vault.local_path
    )

    raise SyncError, "Failed to list vaults: #{stderr}" unless status.success?

    vaults = stdout.lines.map(&:strip)
    unless vaults.include?(@config.obsidian_vault_name)
      raise SyncError, "Vault '#{@config.obsidian_vault_name}' not found in account. Available: #{vaults.join(', ')}"
    end

    @logger.info "[ObsidianSync] Verified vault '#{@config.obsidian_vault_name}' exists"
  end

  # @return [void]
  def connect!
    stdout, stderr, status = Open3.capture3(
      build_credential_env,
      [ cli_bin, "connect", "--vault", @config.obsidian_vault_name.to_s, "--device", @config.device_name.to_s ],
      unsetenv_others: true,
      chdir: @vault.local_path
    )

    raise SyncError, "Connect failed: #{stderr}" unless status.success?

    @logger.info "[ObsidianSync] Connected device '#{@config.device_name}' to vault"
  end

  # @return [void]
  def sync!
    stdout, stderr, status = Open3.capture3(
      build_credential_env,
      [ cli_bin, "sync", "--vault", @config.obsidian_vault_name.to_s ],
      unsetenv_others: true,
      chdir: @vault.local_path
    )

    raise SyncError, "Sync failed: #{stderr}" unless status.success?

    @logger.info "[ObsidianSync] Initial sync completed"
  end

  # @param pid [Integer]
  # @return [Boolean]
  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # @param pid [Integer]
  # @param timeout_seconds [Integer]
  # @return [void]
  def wait_for_exit(pid, timeout_seconds)
    timeout_seconds.times do
      return unless process_alive?(pid)

      sleep 1
    end
  end

  # @param status [String]
  # @param process_pid [Integer, nil]
  # @param error_message [String, nil]
  # @param consecutive_failures [Integer, nil]
  # @return [void]
  def update_status(status, process_pid: nil, error_message: :unchanged, consecutive_failures: :unchanged)
    updates = { process_status: status }
    updates[:process_pid] = process_pid unless process_pid.nil?
    updates[:error_message] = error_message unless error_message == :unchanged
    updates[:consecutive_failures] = consecutive_failures unless consecutive_failures == :unchanged

    if status == "running"
      updates[:last_sync_at] = Time.current
    elsif status.in?(%w[stopped error])
      updates[:process_pid] = nil
    end

    @config.update!(updates)
  end
end
