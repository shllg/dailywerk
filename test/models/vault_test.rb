# frozen_string_literal: true

require "test_helper"

class VaultTest < ActiveSupport::TestCase
  test "computes the local checkout path and enforces size limits" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = Vault.create!(
        name: "Knowledge",
        slug: "knowledge-#{SecureRandom.hex(4)}",
        vault_type: "native",
        current_size_bytes: 10,
        max_size_bytes: 10
      )

      assert_equal(
        Rails.root.join("tmp/workspaces", workspace.id, "vaults", vault.slug).to_s,
        vault.local_path
      )
      assert_predicate vault, :over_limit?
    end
  end

  test "rejects invalid slugs" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      vault = Vault.new(name: "Knowledge", slug: "Bad Slug", vault_type: "native")

      assert_not vault.valid?
      assert_includes vault.errors[:slug], "is invalid"
    end
  end
end
