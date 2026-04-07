# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class MemoryEntryVersionTest < ActiveSupport::TestCase
  test "record! captures the current memory snapshot" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "memory-version-#{SecureRandom.hex(4)}",
        name: "Memory Version",
        model_id: "gpt-5.4"
      )
      session = Session.resolve(agent:)
      entry = MemoryEntry.create!(
        workspace:,
        agent:,
        session:,
        category: "preference",
        content: "User prefers concise answers.",
        source: "manual",
        importance: 8,
        confidence: 0.9,
        metadata: { "origin" => "test" }
      )

      version = MemoryEntryVersion.record!(
        memory_entry: entry,
        action: "updated",
        reason: "Coverage",
        session:,
        editor_user: user,
        editor_agent: agent
      )

      assert_equal workspace.id, version.workspace_id
      assert_equal "updated", version.action
      assert_equal "User prefers concise answers.", version.snapshot["content"]
      assert_equal({ "origin" => "test" }, version.snapshot["metadata"])
      assert_equal entry.id, version.snapshot["id"]
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
