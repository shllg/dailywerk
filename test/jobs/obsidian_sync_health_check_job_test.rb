# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

# rubocop:disable Minitest/MultipleAssertions
class ObsidianSyncHealthCheckJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user, @workspace = create_user_with_workspace(
      email: "obsidian-health-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Obsidian Health"
    )
    @vault = create_vault!
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "schedules a restart when a sync is unhealthy" do
    config = create_sync_config!(@vault, process_status: "running", consecutive_failures: 0)
    fake_manager = Object.new
    original_new = ObsidianSyncManager.method(:new)

    fake_manager.define_singleton_method(:healthy?) do
      false
    end
    fake_manager.define_singleton_method(:stop!) do
      raise "stop should not be called"
    end

    ObsidianSyncManager.define_singleton_method(:new) do |passed_config|
      raise "unexpected config" unless passed_config.id == config.id

      fake_manager
    end

    assert_enqueued_with(job: ObsidianSyncRestartJob, args: [ config.id, { workspace_id: @workspace.id } ]) do
      silence_expected_logs do
        ObsidianSyncHealthCheckJob.perform_now
      end
    end

    config.reload

    assert_equal 1, config.consecutive_failures
    assert_predicate config.last_health_check_at, :present?
    assert_equal "running", config.process_status
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_new)
  end

  test "marks a sync as permanently failed after the final retry" do
    config = create_sync_config!(
      @vault,
      process_status: "running",
      consecutive_failures: VaultSyncConfig::MAX_FAILURES - 1
    )
    calls = []
    fake_manager = Object.new
    original_new = ObsidianSyncManager.method(:new)

    fake_manager.define_singleton_method(:healthy?) do
      false
    end
    fake_manager.define_singleton_method(:stop!) do
      calls << :stop
    end

    ObsidianSyncManager.define_singleton_method(:new) do |passed_config|
      raise "unexpected config" unless passed_config.id == config.id

      fake_manager
    end

    silence_expected_logs do
      ObsidianSyncHealthCheckJob.perform_now
    end

    config.reload

    assert_equal [ :stop ], calls
    assert_equal "error", config.process_status
    assert_equal VaultSyncConfig::MAX_FAILURES, config.consecutive_failures
    assert_match(/failed permanently/, config.error_message)
    assert_no_enqueued_jobs only: ObsidianSyncRestartJob
  ensure
    ObsidianSyncManager.define_singleton_method(:new, original_new)
  end

  private

  def create_vault!
    with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: "Health Vault",
        slug: "health-vault-#{SecureRandom.hex(4)}",
        vault_type: "obsidian",
        status: "active"
      )
    end
  end

  def create_sync_config!(vault, process_status:, consecutive_failures:)
    with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.create!(
        vault: vault,
        workspace: @workspace,
        sync_type: "obsidian",
        sync_mode: "bidirectional",
        obsidian_vault_name: "Health Check",
        device_name: "Health Device",
        process_status: process_status,
        consecutive_failures: consecutive_failures
      )
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
