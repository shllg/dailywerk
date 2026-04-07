# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class VaultLinkTest < ActiveSupport::TestCase
  test "enforces uniqueness per source target and link type" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "vault-link-#{SecureRandom.hex(4)}",
        vault_type: "native"
      )
      source = vault.vault_files.create!(
        workspace:,
        path: "notes/source.md",
        content_hash: "source-hash",
        size_bytes: 20,
        file_type: "markdown"
      )
      target = vault.vault_files.create!(
        workspace:,
        path: "notes/target.md",
        content_hash: "target-hash",
        size_bytes: 20,
        file_type: "markdown"
      )
      VaultLink.create!(
        workspace:,
        source:,
        target:,
        link_type: "wikilink"
      )
      duplicate = VaultLink.new(
        workspace:,
        source:,
        target:,
        link_type: "wikilink"
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:source_id], "has already been taken"
    end
  end

  test "rejects linked files from another workspace" do
    user_one, workspace_one = create_user_with_workspace
    user_two, workspace_two = create_user_with_workspace(
      email: "vault-link-cross-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )

    source = nil
    target = nil

    with_current_workspace(workspace_one, user: user_one) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "vault-link-one-#{SecureRandom.hex(4)}",
        vault_type: "native"
      )
      source = vault.vault_files.create!(
        workspace: workspace_one,
        path: "notes/source.md",
        content_hash: "source-hash",
        size_bytes: 20,
        file_type: "markdown"
      )
    end

    with_current_workspace(workspace_two, user: user_two) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "vault-link-two-#{SecureRandom.hex(4)}",
        vault_type: "native"
      )
      target = vault.vault_files.create!(
        workspace: workspace_two,
        path: "notes/target.md",
        content_hash: "target-hash",
        size_bytes: 20,
        file_type: "markdown"
      )

      link = VaultLink.new(
        workspace: workspace_two,
        source:,
        target:,
        link_type: "wikilink"
      )

      assert_not link.valid?
      assert_includes link.errors[:base], "source and target must belong to the current workspace"
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
