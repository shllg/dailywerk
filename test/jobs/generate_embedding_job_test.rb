# frozen_string_literal: true

require "test_helper"

class GenerateEmbeddingJobTest < ActiveSupport::TestCase
  test "updates the chunk embedding with the provider result" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = Vault.create!(name: "Knowledge", slug: "knowledge", vault_type: "native")
      vault_file = VaultFile.create!(
        vault:,
        workspace:,
        path: "notes/entry.md",
        content_hash: SecureRandom.hex(8),
        size_bytes: 123,
        content_type: "text/markdown",
        file_type: "markdown",
        last_modified: Time.current
      )
      chunk = VaultChunk.create!(
        vault_file:,
        workspace:,
        file_path: "notes/entry.md",
        chunk_idx: 0,
        content: "embedded content #{'x' * 120}"
      )

      with_stubbed_ruby_llm_embed do
        GenerateEmbeddingJob.perform_now("VaultChunk", chunk.id, workspace_id: workspace.id)
      end

      assert_equal 1536, chunk.reload.embedding.length
    end
  end
end
