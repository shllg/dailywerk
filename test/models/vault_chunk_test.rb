# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class VaultChunkTest < ActiveSupport::TestCase
  test "rejects duplicate chunk indexes for the same file" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "chunk-#{SecureRandom.hex(4)}",
        vault_type: "native"
      )
      vault_file = vault.vault_files.create!(
        workspace:,
        path: "notes/today.md",
        content_hash: "abc123",
        size_bytes: 20,
        file_type: "markdown"
      )
      vault_file.vault_chunks.create!(
        workspace:,
        file_path: vault_file.path,
        chunk_idx: 0,
        content: "First chunk"
      )
      duplicate = vault_file.vault_chunks.build(
        workspace:,
        file_path: vault_file.path,
        chunk_idx: 0,
        content: "Duplicate chunk"
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:chunk_idx], "has already been taken"
    end
  end

  test "validates that the vault file belongs to the current workspace" do
    user_one, workspace_one = create_user_with_workspace
    user_two, workspace_two = create_user_with_workspace(
      email: "vault-chunk-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )

    vault_file = with_current_workspace(workspace_one, user: user_one) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "vault-chunk-#{SecureRandom.hex(4)}",
        vault_type: "native"
      )
      vault.vault_files.create!(
        workspace: workspace_one,
        path: "notes/one.md",
        content_hash: "hash",
        size_bytes: 20,
        file_type: "markdown"
      )
    end

    with_current_workspace(workspace_two, user: user_two) do
      chunk = VaultChunk.new(
        workspace: workspace_two,
        vault_file:,
        file_path: vault_file.path,
        chunk_idx: 0,
        content: "Cross-workspace chunk"
      )

      assert_not chunk.valid?
      assert_includes chunk.errors[:vault_file], "must belong to the current workspace"
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
