# frozen_string_literal: true

require "test_helper"

class MessageTest < ActiveSupport::TestCase
  test "active and compacted scopes split messages by compaction state" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      session = create_session_for_tests
      active_message = session.messages.create!(role: "user", content: "Active")
      compacted_message = session.messages.create!(role: "assistant", content: "Compacted", compacted: true)

      assert_equal [ active_message.id ], Message.active.pluck(:id)
      assert_equal [ compacted_message.id ], Message.compacted.pluck(:id)
    end
  end

  test "for_context orders active messages chronologically" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      session = create_session_for_tests
      newer_message = session.messages.create!(role: "assistant", content: "Second")
      older_message = session.messages.create!(role: "user", content: "First")
      older_message.update_columns(created_at: 2.minutes.ago, updated_at: 2.minutes.ago)
      newer_message.update_columns(created_at: 1.minute.ago, updated_at: 1.minute.ago)

      assert_equal [ older_message.id, newer_message.id ], Message.for_context.pluck(:id)
    end
  end

  test "content_for_context prefers media descriptions and stringifies nil content" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      session = create_session_for_tests
      media_message = session.messages.create!(
        role: "user",
        content: nil,
        media_description: "[Image: whiteboard notes]"
      )
      text_message = session.messages.create!(role: "assistant", content: "Plain text")

      assert_equal "[Image: whiteboard notes]", media_message.content_for_context
      assert_equal "Plain text", text_message.content_for_context
    end
  end

  private

  # @return [Session]
  def create_session_for_tests
    agent = Agent.create!(slug: "main-#{SecureRandom.hex(4)}", name: "DailyWerk", model_id: "gpt-5.4")
    Session.resolve(agent:)
  end
end
