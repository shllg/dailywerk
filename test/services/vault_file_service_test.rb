# frozen_string_literal: true

require "test_helper"

class VaultFileServiceTest < ActiveSupport::TestCase
  setup do
    @user, @workspace = create_user_with_workspace
    @vault = nil

    with_current_workspace(@workspace, user: @user) do
      @vault = Vault.create!(
        name: "Knowledge",
        slug: "knowledge-#{SecureRandom.hex(4)}",
        vault_type: "native"
      )
    end
  end

  teardown do
    FileUtils.rm_rf(@vault.local_path) if @vault
  end

  test "writes, reads, lists, and blocks traversal" do
    service = VaultFileService.new(vault: @vault)

    service.write("notes/hello.md", "# Hello\n\nWorld")
    FileUtils.mkdir_p(File.join(@vault.local_path, ".obsidian"))
    File.write(File.join(@vault.local_path, ".obsidian", "workspace.json"), "{}")

    assert_equal "# Hello\n\nWorld", service.read("notes/hello.md")
    assert_equal [ "notes/hello.md" ], service.list

    assert_raises(VaultFileService::PathTraversalError) do
      service.read("../outside.txt")
    end
  end
end
