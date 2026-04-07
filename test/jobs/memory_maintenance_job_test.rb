# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class MemoryMaintenanceJobTest < ActiveSupport::TestCase
  test "deactivates expired memories and lower-ranked duplicates" do
    user, workspace = create_user_with_workspace

    expired_entry = nil
    keeper = nil
    duplicate = nil

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "memory-#{SecureRandom.hex(4)}",
        name: "Memory",
        model_id: "gpt-5.4"
      )
      session = Session.resolve(agent:)

      expired_entry = workspace.memory_entries.create!(
        agent:,
        session:,
        category: "fact",
        content: "Temporary due date",
        source: "system",
        importance: 6,
        confidence: 0.6,
        expires_at: 2.days.ago,
        active: true
      )
      keeper = workspace.memory_entries.create!(
        agent:,
        session:,
        category: "preference",
        content: "User prefers concise answers.",
        source: "system",
        importance: 9,
        confidence: 0.9,
        active: true
      )
      duplicate = workspace.memory_entries.create!(
        agent:,
        session:,
        category: "preference",
        content: "User prefers concise answers.",
        source: "system",
        importance: 3,
        confidence: 0.4,
        active: true
      )
    end

    MemoryMaintenanceJob.perform_now

    with_current_workspace(workspace, user:) do
      assert_not expired_entry.reload.active?
      assert_equal "deactivated", expired_entry.versions.first.action

      assert_predicate keeper.reload, :active?
      assert_not duplicate.reload.active?
      assert_equal "deactivated", duplicate.versions.first.action
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
