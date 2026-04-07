# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class VaultReindexStaleJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "re-enqueues stale chunk embeddings and markdown indexing" do
    user, workspace = create_user_with_workspace

    chunk = nil
    vault_file = nil

    with_current_workspace(workspace, user:) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "reindex-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
      vault_file = vault.vault_files.create!(
        workspace:,
        path: "notes/today.md",
        content_hash: "abc123",
        size_bytes: 20,
        file_type: "markdown"
      )
      chunk = vault_file.vault_chunks.create!(
        workspace:,
        file_path: vault_file.path,
        chunk_idx: 0,
        content: "Daily note content"
      )
    end

    VaultReindexStaleJob.perform_now

    assert_enqueued_with(
      job: GenerateEmbeddingJob,
      args: [ "VaultChunk", chunk.id, { workspace_id: workspace.id } ]
    )
    assert_enqueued_with(
      job: VaultFileChangedJob,
      args: [ vault_file.vault_id, vault_file.path, "modify", { workspace_id: workspace.id } ]
    )
  end
end
