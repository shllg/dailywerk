# frozen_string_literal: true

require_relative "llm_integration_test_case"

class OpenAiEmbeddingIntegrationTest < LlmIntegrationTestCase
  parallelize_me!

  test "GenerateEmbeddingJob stores a live embedding for a vault chunk" do
    require_openai_api_key!

    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "knowledge-#{SecureRandom.hex(4)}",
        vault_type: "native"
      )
      vault_file = VaultFile.create!(
        vault:,
        workspace:,
        path: "notes/live-embedding.md",
        content_hash: SecureRandom.hex(8),
        size_bytes: 128,
        content_type: "text/markdown",
        file_type: "markdown",
        last_modified: Time.current
      )
      chunk = VaultChunk.create!(
        vault_file:,
        workspace:,
        file_path: "notes/live-embedding.md",
        chunk_idx: 0,
        content: "DailyWerk live embedding smoke test."
      )

      GenerateEmbeddingJob.perform_now("VaultChunk", chunk.id, workspace_id: workspace.id)

      embedding = chunk.reload.embedding

      assert_equal VaultChunk::EMBEDDING_DIMENSIONS, embedding.length
      assert embedding.all? { |value| value.is_a?(Numeric) }
      assert_operator embedding.sum(&:abs), :>, 0.0
    end
  end
end
