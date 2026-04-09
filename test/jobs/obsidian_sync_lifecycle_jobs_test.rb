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

  test "setup runs the sync bootstrap flow and enqueues full reindex" do
    calls = []
    fake_manager = Object.new
    fake_vault_manager = Object.new
    original_sync_manager_new = ObsidianSyncManager.method(:new)
    original_vault_manager_new = VaultManager.method(:new)
    config_id = @config.id
    vault_id = @vault.id
    workspace_id = @workspace.id

    fake_manager.define_singleton_method(:setup!) do
      calls << :setup
    end
    fake_manager.define_singleton_method(:start!) do
      calls << :start
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
      ObsidianSyncSetupJob.perform_now(config_id, workspace_id: workspace_id)
    end

    assert_equal [ :setup, :start, [ :analyze, vault_id ] ], calls
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_sync_manager_new)
    VaultManager.define_singleton_method(:new, original_vault_manager_new)
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
        consecutive_failures: consecutive_failures
      )
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
