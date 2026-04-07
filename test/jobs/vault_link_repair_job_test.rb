# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class VaultLinkRepairJobTest < ActiveSupport::TestCase
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
        slug: "knowledge-#{SecureRandom.hex(4)}",
        vault_type: "native"
      )
    end
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
    FileUtils.rm_rf(@vault.local_path) if @vault
  end

  test "sanitizes basename wildcards when searching for stale wikilinks" do
    moved_file = nil
    matching_chunk = nil
    non_matching_chunk = nil

    with_current_workspace(@workspace, user: @user) do
      moved_file = build_vault_file("renamed-note.md")
      matching_file = build_vault_file("matching.md")
      non_matching_file = build_vault_file("non-matching.md")

      matching_chunk = matching_file.vault_chunks.create!(
        file_path: matching_file.path,
        chunk_idx: 0,
        content: "References [[file_100%]] directly."
      )
      non_matching_chunk = non_matching_file.vault_chunks.create!(
        file_path: non_matching_file.path,
        chunk_idx: 0,
        content: "References [[fileA100xyz]] and should not match."
      )
    end

    assert_enqueued_with(
      job: VaultFileChangedJob,
      args: [ @vault.id, matching_chunk.file_path, "modify", { workspace_id: @vault.workspace_id } ]
    ) do
      VaultLinkRepairJob.perform_now(
        @vault.id,
        "file_100%.md",
        moved_file.path,
        workspace_id: @vault.workspace_id
      )
    end

    enqueued_paths = enqueued_jobs
      .select { |job| job[:job] == VaultFileChangedJob }
      .map { |job| job[:args][1] }

    assert_equal [ matching_chunk.file_path ], enqueued_paths
    assert_equal "non-matching.md", non_matching_chunk.file_path
  end

  private

  # @param path [String]
  # @return [VaultFile]
  def build_vault_file(path)
    @vault.vault_files.create!(
      workspace: @workspace,
      path:,
      content_hash: SecureRandom.hex(16),
      size_bytes: 128,
      content_type: "text/markdown",
      file_type: "markdown",
      last_modified: Time.current
    )
  end
end
