# frozen_string_literal: true

require "open3"
require "English"

# Manages the obsidian-headless CLI process for vault sync.
# ALL methods use blocking I/O and must ONLY be called from GoodJob workers.
#
# Architecture: XDG Directory Isolation
# Each VaultSyncConfig gets its own isolated XDG base directory to prevent
# auth token collisions between users. The CLI stores auth tokens, device
# registration, and E2EE keys in these directories.
#
# Layout: {vault_local_base}/{workspace_id}/config/{sync_config_id}/
#   ├── config/obsidian-headless/auth_token
#   ├── data/       (sync history, merkle trees)
#   ├── state/      (E2EE keys, device registration)
#   └── cache/      (temp download cache)
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
  # @param mfa_code [String, nil] Optional MFA TOTP code for 2FA-enabled accounts
  # @return [Boolean] true if setup succeeded
  # @raise [SyncError] if setup fails
  def setup!(mfa_code: nil)
    ensure_cli_available!
    ensure_config_directories!

    # Step 1: Login with credentials
    login!(mfa_code: mfa_code)

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

  # Performs a one-shot sync (ob sync --path).
  # Used by periodic sync job. Does NOT use --continuous.
  #
  # @return [Boolean] true if sync succeeded
  # @raise [SyncError] if sync fails
  def sync!
    ensure_cli_available!

    stdout, stderr, status = run_cli([ "sync", "--path", @vault.local_path ])

    unless status.success?
      # Check for auth errors
      if auth_error?(stderr)
        update_status("auth_required", error_message: "Authentication failed: #{stderr}")
        raise SyncError, "Authentication failed: #{stderr}"
      end

      raise SyncError, "Sync failed: #{stderr}"
    end

    update_status("stopped", error_message: nil, consecutive_failures: 0)
    @logger.info "[ObsidianSync] Sync completed for vault #{@vault.id}"

    true
  rescue StandardError => e
    update_status("error", error_message: e.message) unless @config.process_status == "auth_required"
    raise SyncError, "Sync failed: #{e.message}"
  end

  # @deprecated Use periodic sync via ObsidianSyncPeriodicJob instead
  # Starts the continuous sync process (ob sync --continuous).
  # Uses Process.spawn with XDG environment isolation.
  #
  # @return [Boolean] true if process started
  # @raise [SyncError] if start fails
  def start!
    return true if healthy?

    ensure_cli_available!

    # Stop any existing process first
    stop! if @config.process_pid.present?

    # Prepare environment with XDG isolation
    env = build_env

    # Log files for the process
    log_dir = Rails.root.join("log", "obsidian")
    FileUtils.mkdir_p(log_dir)
    stdout_log = log_dir.join("#{@vault.id}_stdout.log")
    stderr_log = log_dir.join("#{@vault.id}_stderr.log")

    update_status("starting")

    # Spawn the continuous sync process (array form avoids shell injection)
    pid = Process.spawn(
      env,
      cli_bin, "sync", "--continuous", "--path", @vault.local_path,
      unsetenv_others: true,
      pgroup: true,
      out: stdout_log.to_s,
      err: stderr_log.to_s,
      chdir: @vault.local_path
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
  # Uses "stopping" status to preserve PID during shutdown.
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

    # Transition to "stopping" status (preserves PID for recovery if needed)
    update_status("stopping")

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
  # Returns false for "stopping" status (process is shutting down).
  #
  # @return [Boolean]
  def healthy?
    # Not healthy if we're in stopping state
    return false if @config.process_status == "stopping"

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

  # Cleans up the XDG config directory for this sync config.
  # Called during destroy process.
  #
  # @return [Boolean] true if cleanup succeeded or directory didn't exist
  def cleanup_config_directory!
    base_path = config_base_path
    return true unless File.directory?(base_path)

    FileUtils.rm_rf(base_path)
    @logger.info "[ObsidianSync] Cleaned up config directory: #{base_path}"
    true
  rescue StandardError => e
    @logger.error "[ObsidianSync] Failed to cleanup config directory: #{e.message}"
    false
  end

  # @return [String] the base path for XDG config directories
  def config_base_path
    File.join(
      Rails.configuration.x.vault_local_base.presence || Vault::DEFAULT_LOCAL_BASE,
      @config.workspace_id.to_s,
      "config",
      @config.id.to_s
    )
  end

  private

  # @return [void]
  def ensure_cli_available!
    return if File.executable?(cli_bin)

    raise SyncError,
          "obsidian-headless CLI not found: #{configured_cli_bin}. " \
          "Ensure it is on PATH or set OBSIDIAN_HEADLESS_BIN to the absolute binary path."
  end

  # @return [void]
  def ensure_config_directories!
    base = config_base_path

    %w[config data state cache].each do |subdir|
      path = File.join(base, subdir)
      FileUtils.mkdir_p(path)
      FileUtils.chmod(0o700, path)
    end

    @logger.info "[ObsidianSync] Ensured config directories at #{base}"
  end

  # @return [String] path to the obsidian-headless binary
  def cli_bin
    @cli_bin ||= begin
      configured = configured_cli_bin

      if configured.include?(File::SEPARATOR)
        File.expand_path(configured)
      else
        find_executable_on_path(configured) || configured
      end
    end
  end

  # @return [String]
  def configured_cli_bin
    Rails.configuration.x.obsidian_headless_bin.presence || "ob"
  end

  # @param command [String]
  # @return [String, nil]
  def find_executable_on_path(command)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      next if directory.blank?

      candidate = File.join(directory, command)
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end

    nil
  end

  # Builds the environment hash for CLI invocations.
  # Includes PATH, HOME, and isolated XDG directories.
  #
  # @return [Hash] environment variables for CLI
  def build_env
    base = config_base_path

    {
      "PATH" => ENV.fetch("PATH", "/usr/local/bin:/usr/bin:/bin"),
      "HOME" => ENV.fetch("HOME", Dir.home),
      "XDG_CONFIG_HOME" => File.join(base, "config"),
      "XDG_DATA_HOME" => File.join(base, "data"),
      "XDG_STATE_HOME" => File.join(base, "state"),
      "XDG_CACHE_HOME" => File.join(base, "cache")
    }
  end

  # Unified CLI runner using Open3.capture3.
  # Handles environment setup and provides consistent error handling.
  #
  # @param args [Array<String>] CLI arguments (not including binary name)
  # @return [Array<String, String, Process::Status>] stdout, stderr, status
  def run_cli(args)
    env = build_env
    cmd = [ cli_bin ] + args

    @logger.debug "[ObsidianSync] Running: #{cmd.join(' ')}"

    Open3.capture3(
      env,
      *cmd,
      unsetenv_others: true,
      chdir: @vault.local_path
    )
  end

  # @return [void]
  def login!(mfa_code: nil)
    cmd = [
      "login",
      "--email", @config.obsidian_email.to_s,
      "--password", @config.obsidian_password.to_s
    ]
    cmd += [ "--mfa", mfa_code.to_s ] if mfa_code.present?

    stdout, stderr, status = run_cli(cmd)

    unless status.success?
      raise SyncError, "Login failed: #{stderr}"
    end

    @logger.info "[ObsidianSync] Logged in successfully for vault #{@vault.id}"
  end

  # @return [void]
  def verify_vault!
    stdout, stderr, status = run_cli([ "sync-list-remote" ])

    unless status.success?
      raise SyncError, "Failed to list remote vaults: #{stderr}"
    end

    # Output format: <hash>  "<vault_name>"  (<region>)
    # Extract quoted vault names from each line
    vault_names = stdout.lines.filter_map { |line|
      line[/"([^"]+)"/, 1]
    }

    unless vault_names.include?(@config.obsidian_vault_name)
      raise SyncError, "Vault '#{@config.obsidian_vault_name}' not found in account. Available: #{vault_names.join(', ')}"
    end

    @logger.info "[ObsidianSync] Verified vault '#{@config.obsidian_vault_name}' exists"
  end

  # @return [void]
  def connect!
    cmd = [
      "sync-setup",
      "--vault", @config.obsidian_vault_name.to_s,
      "--path", @vault.local_path,
      "--device-name", @config.device_name.to_s
    ]

    # Add E2EE encryption password if configured
    if @config.obsidian_encryption_password.present?
      cmd += [ "--password", @config.obsidian_encryption_password.to_s ]
    end

    stdout, stderr, status = run_cli(cmd)

    unless status.success?
      raise SyncError, "Connect failed: #{stderr}"
    end

    @logger.info "[ObsidianSync] Connected device '#{@config.device_name}' to vault"
  end

  # @param stderr [String]
  # @return [Boolean]
  def auth_error?(stderr)
    return false if stderr.blank?

    # Common auth error patterns from obsidian-headless CLI
    auth_patterns = [
      /unauthorized/i,
      /authentication failed/i,
      /invalid token/i,
      /token expired/i,
      /401/,
      /403/,
      /login required/i
    ]

    auth_patterns.any? { |pattern| stderr.match?(pattern) }
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
  def update_status(status, process_pid: nil, process_host: nil, error_message: :unchanged, consecutive_failures: :unchanged)
    updates = { process_status: status }
    updates[:process_pid] = process_pid unless process_pid.nil?
    updates[:process_host] = process_host unless process_host.nil?
    updates[:error_message] = error_message unless error_message == :unchanged
    updates[:consecutive_failures] = consecutive_failures unless consecutive_failures == :unchanged

    if status == "running"
      updates[:last_sync_at] = Time.current
    elsif status.in?(%w[stopped error auth_required])
      updates[:process_pid] = nil
    end
    # Note: "stopping" preserves PID for recovery tracking

    @config.update!(updates)
  end
end
