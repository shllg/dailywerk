# frozen_string_literal: true

require "digest"
require "test_helper"
require "active_job/test_helper"

# rubocop:disable Minitest/MultipleAssertions
class VaultReconciliationJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    @user, @workspace = create_user_with_workspace
    @vault = with_current_workspace(@workspace, user: @user) do
      Vault.create!(
        name: "Knowledge",
        slug: "reconcile-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
    end
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
    FileUtils.rm_rf(@vault.local_path) if @vault
  end

  test "enqueues create delete and modify events for vault drift" do
    file_service = VaultFileService.new(vault: @vault)
    file_service.write("new-note.md", "# New")
    file_service.write("changed-note.md", "# Changed")
    file_service.write("same-note.md", "# Same")

    with_current_workspace(@workspace, user: @user) do
      @vault.vault_files.create!(
        workspace: @workspace,
        path: "changed-note.md",
        content_hash: "stale-hash",
        size_bytes: 20,
        file_type: "markdown"
      )
      @vault.vault_files.create!(
        workspace: @workspace,
        path: "same-note.md",
        content_hash: Digest::SHA256.file(file_service.resolve_safe_path("same-note.md")).hexdigest,
        size_bytes: 20,
        file_type: "markdown"
      )
      @vault.vault_files.create!(
        workspace: @workspace,
        path: "deleted-note.md",
        content_hash: "deleted-hash",
        size_bytes: 20,
        file_type: "markdown"
      )
    end

    VaultReconciliationJob.perform_now

    matching_jobs = enqueued_jobs.select { |job| job[:job] == VaultFileChangedJob }
    matching_args = matching_jobs.map do |job|
      [
        job[:args][0],
        job[:args][1],
        job[:args][2],
        job[:args][3]["workspace_id"]
      ]
    end

    assert_includes matching_args, [ @vault.id, "new-note.md", "create", @workspace.id ]
    assert_includes matching_args, [ @vault.id, "deleted-note.md", "delete", @workspace.id ]
    assert_includes matching_args, [ @vault.id, "changed-note.md", "modify", @workspace.id ]
    assert_equal 3, matching_jobs.size
  end
end
# rubocop:enable Minitest/MultipleAssertions
