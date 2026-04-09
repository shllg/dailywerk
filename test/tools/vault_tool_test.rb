# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

# rubocop:disable Minitest/MultipleAssertions
class VaultToolTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "write stores file contents and enqueues reindexing" do
    user, workspace, _session, vault, tool = build_tool
    result = nil

    assert_enqueued_with(
      job: VaultFileChangedJob,
      args: [ vault.id, "notes/plan.md", "modify", { workspace_id: workspace.id } ]
    ) do
      result = with_current_workspace(workspace, user:) do
        tool.execute(action: "write", path: "notes/plan.md", content: "# Plan")
      end
    end

    assert_equal "# Plan", VaultFileService.new(vault: vault).read("notes/plan.md")
    assert_equal "written", result[:status]
  end

  test "list_vaults returns all active vaults with metadata" do
    user, workspace, _session, vault, tool = build_tool
    other_vault = with_current_workspace(workspace, user:) do
      vault.update!(file_count: 3)
      Vault.create!(
        name: "Obsidian Notes",
        slug: "obsidian-notes-#{SecureRandom.hex(4)}",
        vault_type: "obsidian",
        status: "active",
        file_count: 12
      )
    end

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "list_vaults")
    end

    assert_equal [ vault.name, other_vault.name ].sort, result.map { |entry| entry[:name] }.sort
    assert_includes result, {
      slug: vault.slug,
      name: vault.name,
      vault_type: vault.vault_type,
      status: vault.status,
      file_count: 3
    }
    assert_includes result, {
      slug: other_vault.slug,
      name: other_vault.name,
      vault_type: other_vault.vault_type,
      status: other_vault.status,
      file_count: 12
    }
  end

  test "list_vaults excludes non-active vaults" do
    user, workspace, _session, vault, tool = build_tool
    with_current_workspace(workspace, user:) do
      Vault.create!(
        name: "Suspended Vault",
        slug: "suspended-vault-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "suspended"
      )
    end

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "list_vaults")
    end

    assert_equal [ vault.slug ], result.map { |entry| entry[:slug] }
  end

  test "list_vaults returns an empty array when no vaults exist" do
    user, workspace = create_user_with_workspace(
      email: "vault-tool-empty-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Empty Vault Tool"
    )

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "vault-tool-empty-#{SecureRandom.hex(4)}",
        name: "Vault Tool Empty",
        model_id: "gpt-5.4"
      )
      Session.resolve(agent:)
    end

    tool = VaultTool.new(user:, session:)

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "list_vaults")
    end

    assert_equal [], result
  end

  test "list respects the glob and hides ignored paths" do
    user, workspace, _session, vault, tool = build_tool
    file_service = VaultFileService.new(vault: vault)

    file_service.write("notes/alpha.md", "alpha")
    file_service.write("tasks/todo.md", "todo")
    file_service.write(".obsidian/workspace.json", "{}")

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "list", glob: "notes/**/*")
    end

    assert_equal [ "notes/alpha.md" ], result.map { |entry| entry[:path] }
  end

  test "read returns content with backlinks and metadata" do
    user, workspace, _session, vault, tool = build_tool
    file_service = VaultFileService.new(vault: vault)

    file_service.write("notes/target.md", "Target body")
    file_service.write("notes/source.md", "Source body")

    target = with_current_workspace(workspace, user:) do
      VaultFile.create!(
        vault: vault,
        path: "notes/target.md",
        title: "Target",
        file_type: "markdown",
        content_type: "text/markdown",
        content_hash: SecureRandom.hex(8),
        tags: [ "reference" ],
        frontmatter: { "kind" => "note" }
      )
    end

    source = with_current_workspace(workspace, user:) do
      VaultFile.create!(
        vault: vault,
        path: "notes/source.md",
        title: "Source",
        file_type: "markdown",
        content_type: "text/markdown",
        content_hash: SecureRandom.hex(8)
      )
    end

    with_current_workspace(workspace, user:) do
      VaultLink.create!(
        workspace: workspace,
        source: source,
        target: target,
        link_type: "wikilink",
        link_text: "[[target]]",
        context: "See target"
      )
    end

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "read", path: "notes/target.md")
    end

    assert_equal "Target body", result[:content]
    assert_equal [ "notes/source.md" ], result[:backlinks]
    assert_equal [ "reference" ], result[:tags]
    assert_equal({ "kind" => "note" }, result[:frontmatter])
  end

  test "update_guide rewrites the requested section and enqueues indexing" do
    user, workspace, _session, vault, tool = build_tool
    file_service = VaultFileService.new(vault: vault)

    file_service.write(
      "_dailywerk/vault-guide.md",
      <<~GUIDE
        # Vault Guide

        ## Folder Structure

        Keep folders tidy.

        ## Agent Behaviors

        Be helpful.
      GUIDE
    )

    result = nil

    assert_enqueued_with(
      job: VaultFileChangedJob,
      args: [ vault.id, "_dailywerk/vault-guide.md", "modify", { workspace_id: workspace.id } ]
    ) do
      result = with_current_workspace(workspace, user:) do
        tool.execute(
          action: "update_guide",
          content: "Prefer project folders by client.",
          section: "folder_structure"
        )
      end
    end

    updated = file_service.read("_dailywerk/vault-guide.md")

    assert_equal "updated", result[:status]
    assert_includes updated, "Prefer project folders by client."
    assert_includes updated, "## Agent Behaviors"
  end

  test "search delegates to the vault search service and truncates snippets" do
    user, workspace, _session, _vault, tool = build_tool
    fake_service = Object.new
    original_new = VaultSearchService.method(:new)

    fake_service.define_singleton_method(:search) do |query, limit:|
      raise "unexpected query" unless query == "security"
      raise "unexpected limit" unless limit == 2

      [
        Struct.new(:file_path, :heading_path, :content).new(
          "notes/security.md",
          "Root > Security",
          "Line 1\nLine 2"
        )
      ]
    end

    VaultSearchService.define_singleton_method(:new) do |vault:|
      raise "unexpected vault" unless vault.workspace_id == workspace.id

      fake_service
    end

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "search", query: "security", limit: 2)
    end

    assert_equal [ "notes/security.md" ], result.map { |entry| entry[:path] }
    assert_equal [ "Root > Security" ], result.map { |entry| entry[:heading_path] }
    assert_equal [ "Line 1 Line 2" ], result.map { |entry| entry[:snippet] }
  ensure
    VaultSearchService.define_singleton_method(:new, original_new)
  end

  test "write rejects ambiguous multi-vault requests when vault_slug is nil" do
    user, workspace, _session, vault, tool = build_tool
    with_current_workspace(workspace, user:) do
      Vault.create!(
        name: "Second Vault",
        slug: "second-vault-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
    end

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "write", path: "notes/plan.md", content: "# Plan", vault_slug: nil)
    end

    assert_equal(
      {
        error: "Multiple vaults exist. Pass vault_slug to specify which one. Use list_vaults to see available slugs."
      },
      result
    )
    refute_includes VaultFileService.new(vault: vault).list(glob: "**/*"), "notes/plan.md"
  end

  test "write targets the requested vault when vault_slug is provided" do
    user, workspace, _session, first_vault, tool = build_tool
    second_vault = with_current_workspace(workspace, user:) do
      Vault.create!(
        name: "Second Vault",
        slug: "second-vault-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
    end

    result = with_current_workspace(workspace, user:) do
      tool.execute(
        action: "write",
        path: "notes/target.md",
        content: "target vault",
        vault_slug: second_vault.slug
      )
    end

    assert_equal "written", result[:status]
    assert_equal "target vault", VaultFileService.new(vault: second_vault).read("notes/target.md")
    refute_includes VaultFileService.new(vault: first_vault).list(glob: "**/*"), "notes/target.md"
  end

  test "write uses the only active vault when vault_slug is nil" do
    user, workspace, _session, vault, tool = build_tool

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "write", path: "notes/default.md", content: "default vault", vault_slug: nil)
    end

    assert_equal "written", result[:status]
    assert_equal "default vault", VaultFileService.new(vault: vault).read("notes/default.md")
  end

  private

  def build_tool(vault_status: "active")
    user, workspace = create_user_with_workspace(
      email: "vault-tool-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Vault Tool"
    )

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "vault-tool-#{SecureRandom.hex(4)}",
        name: "Vault Tool",
        model_id: "gpt-5.4"
      )
      Session.resolve(agent:)
    end

    vault = with_current_workspace(workspace, user:) do
      Vault.create!(
        name: "Knowledge Base",
        slug: "knowledge-base-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: vault_status
      )
    end

    [ user, workspace, session, vault, VaultTool.new(user:, session:) ]
  end
end
# rubocop:enable Minitest/MultipleAssertions
