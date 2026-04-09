# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# rubocop:disable Minitest/MultipleAssertions
class ObsidianSyncManagerTest < ActiveSupport::TestCase
  test "resolves the default ob binary from PATH" do
    with_fake_cli("ob") do |cli_path|
      with_obsidian_headless_bin("ob") do
        with_path(File.dirname(cli_path)) do
          manager = build_manager

          assert_equal cli_path, manager.send(:cli_bin)
          assert_nil manager.send(:ensure_cli_available!)
        end
      end
    end
  end

  test "uses an explicit cli path without PATH lookup" do
    with_fake_cli("custom-ob") do |cli_path|
      with_obsidian_headless_bin(cli_path) do
        with_path("") do
          manager = build_manager

          assert_equal cli_path, manager.send(:cli_bin)
          assert_nil manager.send(:ensure_cli_available!)
        end
      end
    end
  end

  test "raises a helpful error when the cli cannot be resolved" do
    with_obsidian_headless_bin("missing-ob") do
      with_path("") do
        manager = build_manager

        error = assert_raises(ObsidianSyncManager::SyncError) do
          manager.send(:ensure_cli_available!)
        end

        assert_includes error.message, "obsidian-headless CLI not found: missing-ob"
        assert_includes error.message, "OBSIDIAN_HEADLESS_BIN"
      end
    end
  end

  test "build_env includes PATH, HOME, and XDG directories" do
    manager = build_manager
    env = manager.send(:build_env)

    assert_predicate env["PATH"], :present?
    assert_predicate env["HOME"], :present?
    assert_predicate env["XDG_CONFIG_HOME"], :present?
    assert_predicate env["XDG_DATA_HOME"], :present?
    assert_predicate env["XDG_STATE_HOME"], :present?
    assert_predicate env["XDG_CACHE_HOME"], :present?
  end

  test "build_env XDG directories are isolated per config" do
    manager = build_manager
    config = manager.instance_variable_get(:@config)

    env = manager.send(:build_env)
    base_path = manager.config_base_path

    assert_equal File.join(base_path, "config"), env["XDG_CONFIG_HOME"]
    assert_equal File.join(base_path, "data"), env["XDG_DATA_HOME"]
    assert_equal File.join(base_path, "state"), env["XDG_STATE_HOME"]
    assert_equal File.join(base_path, "cache"), env["XDG_CACHE_HOME"]

    # Verify the config_base_path includes the config ID
    assert_includes base_path, config.id.to_s
    assert_includes base_path, config.workspace_id.to_s
  end

  test "config_base_path returns correct path from model" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = create_vault!(workspace)
      config = create_sync_config!(vault, workspace)

      manager = ObsidianSyncManager.new(config)
      manager_path = manager.config_base_path
      model_path = config.config_base_path

      assert_equal manager_path, model_path
      assert_includes manager_path, config.id.to_s
      assert_includes manager_path, workspace.id.to_s
    end
  end

  test "ensure_config_directories! creates directories with 0700 permissions" do
    Dir.mktmpdir("obsidian-test") do |tmp_dir|
      with_vault_local_base(tmp_dir) do
        manager = build_manager

        manager.send(:ensure_config_directories!)

        base = manager.config_base_path
        %w[config data state cache].each do |subdir|
          path = File.join(base, subdir)

          assert File.directory?(path), "Expected #{path} to be a directory"
          mode = File.stat(path).mode & 0o777

          assert_equal 0o700, mode, "Expected #{path} to have 0700 permissions"
        end
      end
    end
  end

  test "cleanup_config_directory! removes the config directory" do
    Dir.mktmpdir("obsidian-test") do |tmp_dir|
      with_vault_local_base(tmp_dir) do
        manager = build_manager

        # Create directories first
        manager.send(:ensure_config_directories!)
        base = manager.config_base_path

        assert File.directory?(base)

        # Cleanup
        result = manager.cleanup_config_directory!

        assert result
        assert_not File.directory?(base)
      end
    end
  end

  test "cleanup_config_directory! returns true when directory doesn't exist" do
    manager = build_manager
    result = manager.cleanup_config_directory!

    assert result
  end

  test "run_cli constructs commands with correct arguments" do
    manager = build_manager
    vault = manager.instance_variable_get(:@vault)

    calls = []
    original_capture3 = Open3.method(:capture3)

    Open3.define_singleton_method(:capture3) do |env, *args|
      opts = args.last.is_a?(Hash) ? args.pop : {}
      calls << { env: env, cmd: args, opts: opts }
      [ "", "", Struct.new(:success?).new(true) ]
    end

    manager.send(:run_cli, [ "sync-list-remote" ])

    assert_equal 1, calls.length
    # CLI bin may be full path or just "ob" depending on PATH
    assert_includes calls.first[:cmd][0], "ob", "Expected command to include 'ob'"
    assert_includes calls.first[:cmd], "sync-list-remote"
    assert_equal vault.local_path, calls.first[:opts][:chdir]
    assert calls.first[:opts][:unsetenv_others]
  ensure
    Open3.define_singleton_method(:capture3, original_capture3)
  end

  test "run_cli includes XDG environment variables" do
    manager = build_manager

    calls = []
    original_capture3 = Open3.method(:capture3)

    Open3.define_singleton_method(:capture3) do |env, *args|
      calls << { env: env }
      [ "", "", Struct.new(:success?).new(true) ]
    end

    manager.send(:run_cli, [ "sync-list-remote" ])

    env = calls.first[:env]

    assert_predicate env["PATH"], :present?
    assert_predicate env["HOME"], :present?
    assert_predicate env["XDG_CONFIG_HOME"], :present?
  ensure
    Open3.define_singleton_method(:capture3, original_capture3)
  end

  test "login! includes --email and --password flags" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = create_vault!(workspace)
      config = create_sync_config!(
        vault,
        workspace,
        obsidian_email: "test@example.com",
        obsidian_password: "secret123"
      )

      manager = ObsidianSyncManager.new(config)

      calls = []
      original_capture3 = Open3.method(:capture3)

      Open3.define_singleton_method(:capture3) do |env, *args|
        args.pop if args.last.is_a?(Hash)
        calls << { cmd: args }
        [ "", "", Struct.new(:success?).new(true) ]
      end

      manager.send(:login!)

      assert_equal 1, calls.length
      cmd = calls.first[:cmd]

      assert_includes cmd, "login"
      assert_includes cmd, "--email"
      assert_includes cmd, "test@example.com"
      assert_includes cmd, "--password"
      assert_includes cmd, "secret123"
    ensure
      Open3.define_singleton_method(:capture3, original_capture3)
    end
  end

  test "login! includes --mfa flag when mfa_code provided" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = create_vault!(workspace)
      config = create_sync_config!(vault, workspace)

      manager = ObsidianSyncManager.new(config)

      calls = []
      original_capture3 = Open3.method(:capture3)

      Open3.define_singleton_method(:capture3) do |env, *args|
        args.pop if args.last.is_a?(Hash)
        calls << { cmd: args }
        [ "", "", Struct.new(:success?).new(true) ]
      end

      manager.send(:login!, mfa_code: "123456")

      cmd = calls.first[:cmd]

      assert_includes cmd, "--mfa"
      assert_includes cmd, "123456"
    ensure
      Open3.define_singleton_method(:capture3, original_capture3)
    end
  end

  test "verify_vault! uses sync-list-remote command" do
    manager = build_manager
    config = manager.instance_variable_get(:@config)

    calls = []
    original_capture3 = Open3.method(:capture3)

    # Return vault list that includes the configured vault name
    Open3.define_singleton_method(:capture3) do |env, *args|
      args.pop if args.last.is_a?(Hash)
      calls << { cmd: args }
      vault_output = <<~OUTPUT
        Fetching vaults...

        Vaults:
        abc123  "#{config.obsidian_vault_name}"  (Europe)
        def456  "Other Vault"  (Europe)
      OUTPUT
      [ vault_output, "", Struct.new(:success?).new(true) ]
    end

    manager.send(:verify_vault!)

    assert_equal 1, calls.length
    assert_includes calls.first[:cmd], "sync-list-remote"
  ensure
    Open3.define_singleton_method(:capture3, original_capture3)
  end

  test "connect! uses sync-setup with correct arguments" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = create_vault!(workspace)
      config = create_sync_config!(
        vault,
        workspace,
        obsidian_vault_name: "My Test Vault",
        device_name: "DailyWerk Device",
        obsidian_encryption_password: "vault-pass"
      )

      manager = ObsidianSyncManager.new(config)

      calls = []
      original_capture3 = Open3.method(:capture3)

      Open3.define_singleton_method(:capture3) do |env, *args|
        args.pop if args.last.is_a?(Hash)
        calls << { cmd: args }
        [ "", "", Struct.new(:success?).new(true) ]
      end

      manager.send(:connect!)

      cmd = calls.first[:cmd]

      assert_includes cmd, "sync-setup"
      assert_includes cmd, "--vault"
      assert_includes cmd, "My Test Vault"
      assert_includes cmd, "--path"
      assert_includes cmd, vault.local_path
      assert_includes cmd, "--device-name"
      assert_includes cmd, "DailyWerk Device"
      assert_includes cmd, "--password"
      assert_includes cmd, "vault-pass"
    ensure
      Open3.define_singleton_method(:capture3, original_capture3)
    end
  end

  test "sync! uses ob sync with --path argument" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = create_vault!(workspace)
      config = create_sync_config!(vault, workspace)

      manager = ObsidianSyncManager.new(config)

      calls = []
      original_capture3 = Open3.method(:capture3)

      Open3.define_singleton_method(:capture3) do |env, *args|
        args.pop if args.last.is_a?(Hash)
        calls << { cmd: args }
        [ "", "", Struct.new(:success?).new(true) ]
      end

      manager.sync!

      cmd = calls.first[:cmd]

      assert_includes cmd, "sync"
      assert_includes cmd, "--path"
      assert_includes cmd, vault.local_path
      assert_not_includes cmd, "--vault"
    ensure
      Open3.define_singleton_method(:capture3, original_capture3)
    end
  end

  test "auth_error? detects common auth failure patterns" do
    manager = build_manager

    assert manager.send(:auth_error?, "Unauthorized access")
    assert manager.send(:auth_error?, "Authentication failed")
    assert manager.send(:auth_error?, "Token expired")
    assert manager.send(:auth_error?, "Invalid token provided")
    assert manager.send(:auth_error?, "Received 401 from server")
    assert manager.send(:auth_error?, "403 Forbidden")
    assert manager.send(:auth_error?, "Login required")

    assert_not manager.send(:auth_error?, "Network timeout")
    assert_not manager.send(:auth_error?, "")
    assert_not manager.send(:auth_error?, nil)
  end

  test "sync! transitions to auth_required on auth failure" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = create_vault!(workspace)
      config = create_sync_config!(vault, workspace)

      manager = ObsidianSyncManager.new(config)

      original_capture3 = Open3.method(:capture3)
      Open3.define_singleton_method(:capture3) do |env, *_args|
        [ "", "Unauthorized: Invalid token", Struct.new(:success?).new(false) ]
      end

      error = assert_raises(ObsidianSyncManager::SyncError) do
        manager.sync!
      end

      assert_includes error.message, "Authentication failed"
      assert_equal "auth_required", config.reload.process_status
    ensure
      Open3.define_singleton_method(:capture3, original_capture3)
    end
  end

  test "healthy? returns false when status is stopping" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = create_vault!(workspace)
      config = create_sync_config!(
        vault, workspace,
        process_status: "stopping",
        process_pid: 12345,
        obsidian_email: "test@example.com",
        obsidian_password: "password123"
      )

      manager = ObsidianSyncManager.new(config)

      # Even with a PID, stopping status means not healthy
      assert_not manager.healthy?
    end
  end

  test "update_status clears PID for stopped, error, auth_required" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = create_vault!(workspace)
      config = create_sync_config!(
        vault, workspace,
        process_status: "running",
        process_pid: 12345,
        obsidian_email: "test@example.com",
        obsidian_password: "password123"
      )

      manager = ObsidianSyncManager.new(config)

      manager.send(:update_status, "stopped")

      assert_nil config.reload.process_pid

      config.update!(process_pid: 12345)
      manager.send(:update_status, "error")

      assert_nil config.reload.process_pid

      config.update!(process_pid: 12345)
      manager.send(:update_status, "auth_required")

      assert_nil config.reload.process_pid
    end
  end

  test "update_status preserves PID for stopping status" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = create_vault!(workspace)
      config = create_sync_config!(
        vault, workspace,
        process_status: "running",
        process_pid: 12345,
        obsidian_email: "test@example.com",
        obsidian_password: "password123"
      )

      manager = ObsidianSyncManager.new(config)
      manager.send(:update_status, "stopping")

      # stopping status preserves PID for recovery
      assert_equal 12345, config.reload.process_pid
    end
  end

  private

  def build_manager
    user, workspace = create_user_with_workspace(
      email: "obsidian-sync-manager-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Obsidian Sync Manager"
    )

    with_current_workspace(workspace, user:) do
      vault = Vault.create!(
        name: "Obsidian Vault",
        slug: "obsidian-vault-#{SecureRandom.hex(4)}",
        vault_type: "obsidian",
        status: "active"
      )

      config = VaultSyncConfig.create!(
        vault: vault,
        workspace: workspace,
        sync_type: "obsidian",
        sync_mode: "bidirectional",
        obsidian_vault_name: "Test Vault",
        device_name: "Test Device",
        process_status: "stopped",
        obsidian_email_enc: "test@example.com",
        obsidian_password_enc: "password123"
      )

      ObsidianSyncManager.new(config)
    end
  end

  def create_vault!(workspace)
    Vault.create!(
      name: "Obsidian Vault",
      slug: "obsidian-vault-#{SecureRandom.hex(4)}",
      vault_type: "obsidian",
      status: "active"
    )
  end

  def create_sync_config!(
    vault,
    workspace,
    process_status: "stopped",
    process_pid: nil,
    obsidian_vault_name: "Test Vault",
    device_name: "Test Device",
    obsidian_email: nil,
    obsidian_password: nil,
    obsidian_encryption_password: nil
  )
    VaultSyncConfig.create!(
      vault: vault,
      workspace: workspace,
      sync_type: "obsidian",
      sync_mode: "bidirectional",
      obsidian_vault_name: obsidian_vault_name,
      device_name: device_name,
      process_status: process_status,
      process_pid: process_pid,
      obsidian_email_enc: obsidian_email,
      obsidian_password_enc: obsidian_password,
      obsidian_encryption_password_enc: obsidian_encryption_password
    )
  end

  def with_fake_cli(name)
    Dir.mktmpdir("obsidian-cli") do |dir|
      path = File.join(dir, name)
      File.write(path, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, path)
      yield path
    end
  end

  def with_obsidian_headless_bin(value)
    original = Rails.configuration.x.obsidian_headless_bin
    Rails.configuration.x.obsidian_headless_bin = value
    yield
  ensure
    Rails.configuration.x.obsidian_headless_bin = original
  end

  def with_path(value)
    original = ENV["PATH"]
    ENV["PATH"] = value
    yield
  ensure
    ENV["PATH"] = original
  end

  def with_vault_local_base(value)
    original = Rails.configuration.x.vault_local_base
    Rails.configuration.x.vault_local_base = value
    yield
  ensure
    Rails.configuration.x.vault_local_base = original
  end
end
# rubocop:enable Minitest/MultipleAssertions
