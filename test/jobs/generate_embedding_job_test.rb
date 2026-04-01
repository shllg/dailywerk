# frozen_string_literal: true

require "test_helper"

class GenerateEmbeddingJobTest < ActiveSupport::TestCase
  test "updates the chunk embedding with the provider result" do
    user, workspace = create_user_with_workspace
    original_embed = RubyLLM.method(:embed)

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

      RubyLLM.define_singleton_method(:embed) do |_content|
        Struct.new(:vectors).new(Array.new(1536, 0.1))
      end

      GenerateEmbeddingJob.perform_now("VaultChunk", chunk.id, workspace_id: workspace.id)

      assert_equal 1536, chunk.reload.embedding.length
    end
  ensure
    RubyLLM.define_singleton_method(:embed, original_embed)
  end
end
