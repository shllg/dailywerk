# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class Api::V1::VaultsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user, @workspace = create_user_with_workspace
    @original_vault_local_base = Rails.configuration.x.vault_local_base
    @temp_local_base = Dir.mktmpdir("vault-controller-test")
    Rails.configuration.x.vault_local_base = @temp_local_base
  end

  teardown do
    Rails.configuration.x.vault_local_base = @original_vault_local_base
    FileUtils.rm_rf(@temp_local_base) if @temp_local_base
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "index lists workspace vaults" do
    vault = create_vault!(name: "Knowledge Base")

    get "/api/v1/vaults", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal 1, body["vaults"].length
    assert_equal vault.name, body["vaults"].first["name"]
    assert_equal "native", body["vaults"].first["vault_type"]
  end

  test "index does not include full sync_config to keep response light" do
    vault = create_vault!(name: "Obsidian Vault", vault_type: "obsidian")
    create_sync_config!(vault)

    get "/api/v1/vaults", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    # Index uses summary only, sync_config only in full/show
    refute body["vaults"].first.key?("sync_config")
  end

  test "show returns vault with recent files" do
    vault = create_vault!(name: "Test Vault")
    file = create_vault_file!(vault, path: "notes/hello.md", title: "Hello Note")

    get "/api/v1/vaults/#{vault.id}", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal vault.id, body["vault"]["id"]
    assert_equal 1, body["vault"]["recent_files"].length
    assert_equal "notes/hello.md", body["vault"]["recent_files"].first["path"]
  end

  test "create makes a new vault with seed files" do
    assert_enqueued_jobs 2, only: VaultFileChangedJob do
      post "/api/v1/vaults",
           params: { vault: { name: "New Vault", vault_type: "native" } },
           as: :json,
           headers: api_auth_headers(user: @user, workspace: @workspace)

      assert_response :created
      body = JSON.parse(response.body)

      assert_equal "New Vault", body["vault"]["name"]
      assert_equal "native", body["vault"]["vault_type"]
      assert_equal "new-vault", body["vault"]["slug"]
      assert_equal 2, body["vault"]["file_count"]
    end
  end

  test "create enqueues VaultFileChangedJob for seed files" do
    post "/api/v1/vaults",
         params: { vault: { name: "Seeded Vault", vault_type: "native" } },
         as: :json,
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :created

    # Verify the jobs were enqueued with correct paths
    jobs = enqueued_jobs.select { |j| j["job_class"] == "VaultFileChangedJob" }

    assert_equal 2, jobs.length

    paths = jobs.map { |j| j["arguments"][1] }

    assert_includes paths, "_dailywerk/README.md"
    assert_includes paths, "_dailywerk/vault-guide.md"
  end

  test "create accepts obsidian vault type" do
    post "/api/v1/vaults",
         params: { vault: { name: "Obsidian Notes", vault_type: "obsidian" } },
         as: :json,
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :created
    body = JSON.parse(response.body)

    assert_equal "obsidian", body["vault"]["vault_type"]
  end

  test "destroy deletes vault and stops running sync" do
    vault = create_vault!(name: "To Delete", vault_type: "obsidian")
    sync_config = create_sync_config!(vault, process_status: "running")

    assert_enqueued_with(job: ObsidianSyncStopJob, args: [ sync_config.id, { workspace_id: @workspace.id } ]) do
      delete "/api/v1/vaults/#{vault.id}", headers: api_auth_headers(user: @user, workspace: @workspace)

      assert_response :accepted
      body = JSON.parse(response.body)

      assert_equal "Vault deletion queued. Sync process is being stopped.", body["message"]
    end
  end

  test "destroy removes vault immediately when sync stopped" do
    vault = create_vault!(name: "To Delete", vault_type: "native")

    delete "/api/v1/vaults/#{vault.id}", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :no_content
    assert_nil Vault.find_by(id: vault.id)
  end

  test "returns 404 for non-existent vault" do
    get "/api/v1/vaults/non-existent-id", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :not_found
  end

  private

  def create_vault!(name:, vault_type: "native")
    with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: name,
        slug: "#{name.parameterize}-#{SecureRandom.hex(4)}",
        vault_type: vault_type,
        status: "active"
      )
    end
  end

  def create_vault_file!(vault, path:, title: nil)
    with_current_workspace(@workspace, user: @user) do
      VaultFile.create!(
        vault: vault,
        path: path,
        title: title,
        file_type: "markdown",
        content_type: "text/markdown",
        content_hash: SecureRandom.hex(8)
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
        process_status: process_status
      )
    end
  end
end
