# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

# rubocop:disable Minitest/MultipleAssertions
class ObsidianSyncLifecycleJobsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user, @workspace = create_user_with_workspace(
      email: "obsidian-jobs-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Obsidian Jobs"
    )
    @vault = create_vault!
    @config = create_sync_config!(@vault)
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "start delegates to the sync manager" do
    calls = []
    fake_manager = Object.new
    original_new = ObsidianSyncManager.method(:new)
    config_id = @config.id
    workspace_id = @workspace.id

    fake_manager.define_singleton_method(:start!) do
      calls << :start
    end

    ObsidianSyncManager.define_singleton_method(:new) do |config|
      raise "unexpected config" unless config.id == config_id

      fake_manager
    end

    ObsidianSyncStartJob.perform_now(config_id, workspace_id: workspace_id)

    assert_equal [ :start ], calls
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_new)
  end

  test "stop delegates to the sync manager" do
    calls = []
    fake_manager = Object.new
    original_new = ObsidianSyncManager.method(:new)
    config_id = @config.id
    workspace_id = @workspace.id

    fake_manager.define_singleton_method(:stop!) do
      calls << :stop
    end

    ObsidianSyncManager.define_singleton_method(:new) do |config|
      raise "unexpected config" unless config.id == config_id

      fake_manager
    end

    ObsidianSyncStopJob.perform_now(config_id, workspace_id: workspace_id)

    assert_equal [ :stop ], calls
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_new)
  end

  test "restart delegates to the sync manager" do
    calls = []
    fake_manager = Object.new
    original_new = ObsidianSyncManager.method(:new)
    config_id = @config.id
    workspace_id = @workspace.id

    fake_manager.define_singleton_method(:restart!) do
      calls << :restart
    end

    ObsidianSyncManager.define_singleton_method(:new) do |config|
      raise "unexpected config" unless config.id == config_id

      fake_manager
    end

    ObsidianSyncRestartJob.perform_now(config_id, workspace_id: workspace_id)

    assert_equal [ :restart ], calls
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_new)
  end

  test "setup runs the sync bootstrap flow with MFA and enqueues full reindex" do
    calls = []
    fake_manager = Object.new
    fake_vault_manager = Object.new
    original_sync_manager_new = ObsidianSyncManager.method(:new)
    original_vault_manager_new = VaultManager.method(:new)
    config_id = @config.id
    vault_id = @vault.id
    workspace_id = @workspace.id

    fake_manager.define_singleton_method(:setup!) do |mfa_code: nil|
      calls << [ :setup, mfa_code ]
    end
    fake_vault_manager.define_singleton_method(:analyze_and_guide) do |vault|
      calls << [ :analyze, vault.id ]
    end

    ObsidianSyncManager.define_singleton_method(:new) do |config|
      raise "unexpected config" unless config.id == config_id

      fake_manager
    end
    VaultManager.define_singleton_method(:new) do |workspace:|
      raise "unexpected workspace" unless workspace.id == workspace_id

      fake_vault_manager
    end

    assert_enqueued_with(job: VaultFullReindexJob, args: [ vault_id, { workspace_id: workspace_id } ]) do
      ObsidianSyncSetupJob.perform_now(config_id, workspace_id: workspace_id, mfa_code: "123456")
    end

    assert_equal [ [ :setup, "123456" ], [ :analyze, vault_id ] ], calls
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_sync_manager_new)
    VaultManager.define_singleton_method(:new, original_vault_manager_new)
  end

  test "setup passes nil mfa_code when not provided" do
    calls = []
    fake_manager = Object.new
    original_new = ObsidianSyncManager.method(:new)
    config_id = @config.id
    workspace_id = @workspace.id

    fake_manager.define_singleton_method(:setup!) do |mfa_code: nil|
      calls << [ :setup, mfa_code ]
    end

    ObsidianSyncManager.define_singleton_method(:new) do |config|
      raise "unexpected config" unless config.id == config_id

      fake_manager
    end

    ObsidianSyncSetupJob.perform_now(config_id, workspace_id: workspace_id)

    assert_equal [ [ :setup, nil ] ], calls
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_new)
  end

  test "jobs have concurrency controls" do
    # Verify all sync jobs have the concurrency extension
    setup_job = ObsidianSyncSetupJob

    assert_respond_to setup_job, :good_job_control_concurrency_with

    start_job = ObsidianSyncStartJob

    assert_respond_to start_job, :good_job_control_concurrency_with

    stop_job = ObsidianSyncStopJob

    assert_respond_to stop_job, :good_job_control_concurrency_with

    restart_job = ObsidianSyncRestartJob

    assert_respond_to restart_job, :good_job_control_concurrency_with
  end

  test "destroy job stops process and cleans up config directory" do
    calls = []
    original_rm_rf = nil
    original_kill = nil
    original_getpgid = nil

    with_current_workspace(@workspace, user: @user) do
      # Create config with specific values
      config = @config
      config.update!(
        process_pid: 12345,
        process_host: Socket.gethostname,
        process_status: "running"
      )
      base_path = config.config_base_path
      FileUtils.mkdir_p(base_path) # Ensure directory exists

      # Mock FileUtils.rm_rf
      original_rm_rf = FileUtils.method(:rm_rf)
      FileUtils.define_singleton_method(:rm_rf) do |path|
        calls << [ :rm_rf, path ]
      end

      # Stub Process.kill to capture calls
      kill_calls = []
      original_kill = Process.method(:kill)
      Process.define_singleton_method(:kill) do |signal, pid|
        kill_calls << [ signal, pid ]
      end

      # Stub Process.getpgid to return the PID
      original_getpgid = Process.method(:getpgid)
      Process.define_singleton_method(:getpgid) do |pid|
        pid
      end

      # Run the destroy job
      ObsidianSyncDestroyJob.perform_now(
        config.id,
        workspace_id: @workspace.id,
        process_pid: 12345,
        process_host: Socket.gethostname,
        config_base_path: base_path
      )

      # Verify stop was attempted (SIGTERM)
      assert_includes kill_calls, [ "TERM", -12345 ]

      # Verify cleanup was called
      assert_equal [ [ :rm_rf, base_path ] ], calls

      # Verify record was deleted
      assert_nil VaultSyncConfig.find_by(id: config.id)
    end
  ensure
    FileUtils.define_singleton_method(:rm_rf, original_rm_rf) if original_rm_rf
    Process.define_singleton_method(:kill, original_kill) if original_kill
    Process.define_singleton_method(:getpgid, original_getpgid) if original_getpgid
  end

  test "periodic job runs sync and handles success" do
    calls = []
    fake_manager = Object.new
    original_new = ObsidianSyncManager.method(:new)
    config_id = @config.id
    workspace_id = @workspace.id

    fake_manager.define_singleton_method(:sync!) do
      calls << :sync
    end

    ObsidianSyncManager.define_singleton_method(:new) do |config|
      raise "unexpected config" unless config.id == config_id

      fake_manager
    end

    ObsidianSyncPeriodicJob.perform_now(config_id, workspace_id: workspace_id)

    assert_equal [ :sync ], calls
    assert_equal "stopped", @config.reload.process_status
    assert_equal 0, @config.consecutive_failures
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_new)
  end

  test "periodic job handles auth error" do
    fake_manager = Object.new
    original_new = ObsidianSyncManager.method(:new)
    config_id = @config.id
    workspace_id = @workspace.id

    fake_manager.define_singleton_method(:sync!) do
      raise ObsidianSyncManager::SyncError, "Authentication failed: Invalid token"
    end

    ObsidianSyncManager.define_singleton_method(:new) do |config|
      raise "unexpected config" unless config.id == config_id

      fake_manager
    end

    assert_raises(ObsidianSyncManager::SyncError) do
      ObsidianSyncPeriodicJob.perform_now(config_id, workspace_id: workspace_id)
    end

    @config.reload

    assert_equal "auth_required", @config.process_status
    assert_includes @config.error_message, "Authentication failed"
    assert_equal 0, @config.consecutive_failures
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_new)
  end

  test "periodic all job enqueues syncs for available configs" do
    with_current_workspace(@workspace, user: @user) do
      # Create another config
      vault2 = create_vault!
      config2 = create_sync_config!(vault2, process_status: "stopped")

      @config.update!(process_status: "stopped")

      assert_enqueued_jobs 2, only: ObsidianSyncPeriodicJob do
        ObsidianSyncPeriodicAllJob.perform_now
      end
    end
  end

  private

  def create_vault!
    with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: "Obsidian Notes",
        slug: "obsidian-notes-#{SecureRandom.hex(4)}",
        vault_type: "obsidian",
        status: "active"
      )
    end
  end

  def create_sync_config!(vault, process_status: "stopped", consecutive_failures: 0)
    with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.create!(
        vault: vault,
        workspace: @workspace,
        sync_type: "obsidian",
        sync_mode: "bidirectional",
        obsidian_vault_name: "Test Vault",
        device_name: "Test Device",
        process_status: process_status,
        consecutive_failures: consecutive_failures,
        obsidian_email_enc: "test@example.com",
        obsidian_password_enc: "password123"
      )
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
