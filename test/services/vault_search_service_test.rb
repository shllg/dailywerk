# frozen_string_literal: true

require "test_helper"

class VaultSearchServiceTest < ActiveSupport::TestCase
  test "returns full-text matches from the current vault" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "knowledge-#{SecureRandom.hex(4)}",
        vault_type: "obsidian",
        status: "active",
        max_size_bytes: 2.gigabytes
      )
      vault_file = vault.vault_files.create!(
        workspace: workspace,
        path: "notes/search.md",
        content_hash: SecureRandom.hex(32),
        size_bytes: 128,
        content_type: "text/markdown",
        file_type: "markdown",
        title: "Search"
      )
      chunk = vault_file.vault_chunks.create!(
        workspace: workspace,
        file_path: vault_file.path,
        chunk_idx: 0,
        content: "alpha beta gamma"
      )

      results = with_stubbed_ruby_llm_embed do
        VaultSearchService.new(vault: vault).search("beta")
      end

      assert_equal [ chunk.id ], results.map(&:id)
    end
  end
end
