# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class VaultFullReindexJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user, @workspace = create_user_with_workspace(
      email: "vault-reindex-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Vault Reindex"
    )
    @vault = with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: "Reindex Vault",
        slug: "reindex-vault-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
    end
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "enqueues indexing for every file in the vault" do
    file_service = VaultFileService.new(vault: @vault)
    file_service.write("notes/alpha.md", "alpha")
    file_service.write("notes/beta.md", "beta")

    assert_enqueued_jobs 2, only: VaultFileChangedJob do
      VaultFullReindexJob.perform_now(@vault.id, workspace_id: @workspace.id)
    end

    jobs = enqueued_jobs.select { |job| job["job_class"] == "VaultFileChangedJob" }
    paths = jobs.map { |job| job["arguments"][1] }.sort

    assert_equal [ "notes/alpha.md", "notes/beta.md" ], paths
  end
end
