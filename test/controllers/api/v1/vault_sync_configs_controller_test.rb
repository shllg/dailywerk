# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class Api::V1::VaultSyncConfigsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user, @workspace = create_user_with_workspace
    @vault = create_vault!(name: "Obsidian Vault", vault_type: "obsidian")
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "update creates new sync config" do
    put "/api/v1/vaults/#{@vault.id}/sync_config",
        params: {
          sync_config: {
            sync_type: "obsidian",
            sync_mode: "bidirectional",
            obsidian_vault_name: "My Second Brain",
            device_name: "DailyWerk Server",
            obsidian_email: "user@example.com",
            obsidian_password: "secret123",
            obsidian_encryption_password: "encryption456"
          }
        },
        as: :json,
        headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal "obsidian", body["sync_config"]["sync_type"]
    assert_equal "bidirectional", body["sync_config"]["sync_mode"]
    assert_equal "My Second Brain", body["sync_config"]["obsidian_vault_name"]
    assert_equal "DailyWerk Server", body["sync_config"]["device_name"]
    assert_equal true, body["sync_config"]["has_email"]
    assert_equal true, body["sync_config"]["has_password"]
    assert_equal true, body["sync_config"]["has_encryption_password"]

    # Credentials should NOT be in the response
    refute body["sync_config"].key?("obsidian_email")
    refute body["sync_config"].key?("obsidian_password")
  end

  test "update modifies existing sync config" do
    create_sync_config!(@vault)

    put "/api/v1/vaults/#{@vault.id}/sync_config",
        params: {
          sync_config: {
            sync_mode: "pull_only",
            device_name: "New Device Name"
          }
        },
        as: :json,
        headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal "pull_only", body["sync_config"]["sync_mode"]
    assert_equal "New Device Name", body["sync_config"]["device_name"]
  end

  test "destroy removes sync config" do
    create_sync_config!(@vault)

    delete "/api/v1/vaults/#{@vault.id}/sync_config", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :no_content
    assert_nil @vault.reload.sync_config
  end

  test "destroy enqueues stop job when sync running" do
    config = create_sync_config!(@vault, process_status: "running")

    assert_enqueued_with(job: ObsidianSyncStopJob, args: [ config.id, { workspace_id: @workspace.id } ]) do
      delete "/api/v1/vaults/#{@vault.id}/sync_config", headers: api_auth_headers(user: @user, workspace: @workspace)
    end
  end

  test "destroy returns 404 when no config exists" do
    delete "/api/v1/vaults/#{@vault.id}/sync_config", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :not_found
    body = JSON.parse(response.body)

    assert_equal "Sync config not found", body["error"]
  end

  test "setup enqueues ObsidianSyncSetupJob" do
    create_sync_config!(@vault)

    assert_enqueued_with(job: ObsidianSyncSetupJob) do
      post "/api/v1/vaults/#{@vault.id}/sync_config/setup",
           headers: api_auth_headers(user: @user, workspace: @workspace)
    end

    assert_response :accepted
    body = JSON.parse(response.body)

    assert_equal "Obsidian sync setup queued.", body["message"]
  end

  test "setup returns 404 when no config exists" do
    post "/api/v1/vaults/#{@vault.id}/sync_config/setup",
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :not_found
  end

  test "start enqueues ObsidianSyncStartJob" do
    config = create_sync_config!(@vault)

    assert_enqueued_with(job: ObsidianSyncStartJob, args: [ config.id, { workspace_id: @workspace.id } ]) do
      post "/api/v1/vaults/#{@vault.id}/sync_config/start",
           headers: api_auth_headers(user: @user, workspace: @workspace)
    end

    assert_response :accepted
    body = JSON.parse(response.body)

    assert_equal "Obsidian sync start queued.", body["message"]
  end

  test "start returns 404 when no config exists" do
    post "/api/v1/vaults/#{@vault.id}/sync_config/start",
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :not_found
  end

  test "stop enqueues ObsidianSyncStopJob" do
    config = create_sync_config!(@vault, process_status: "running")

    assert_enqueued_with(job: ObsidianSyncStopJob, args: [ config.id, { workspace_id: @workspace.id } ]) do
      post "/api/v1/vaults/#{@vault.id}/sync_config/stop",
           headers: api_auth_headers(user: @user, workspace: @workspace)
    end

    assert_response :accepted
    body = JSON.parse(response.body)

    assert_equal "Obsidian sync stop queued.", body["message"]
  end

  test "stop returns 404 when no config exists" do
    post "/api/v1/vaults/#{@vault.id}/sync_config/stop",
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :not_found
  end

  test "requires admin access" do
    # Create a non-admin user
    member_user = User.create!(
      email: "member-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Member",
      status: "active"
    )
    WorkspaceMembership.create!(
      workspace: @workspace,
      user: member_user,
      role: "member"  # Not admin
    )

    put "/api/v1/vaults/#{@vault.id}/sync_config",
        params: { sync_config: { sync_type: "obsidian" } },
        as: :json,
        headers: api_auth_headers(user: member_user, workspace: @workspace)

    assert_response :forbidden
  end

  private

  def create_vault!(name:, vault_type:)
    with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: name,
        slug: "#{name.parameterize}-#{SecureRandom.hex(4)}",
        vault_type: vault_type,
        status: "active"
      )
    end
  end

  def create_sync_config!(vault, process_status: "stopped")
    with_current_workspace(@workspace, user: @user) do
      VaultSyncConfig.create!(
        vault: vault,
        workspace: @workspace,
        sync_type: "obsidian",
        sync_mode: "bidirectional",
        obsidian_vault_name: "Test Vault",
        device_name: "Test Device",
        process_status: process_status,
        obsidian_email_enc: "user@example.com",
        obsidian_password_enc: "secret"
      )
    end
  end
end
