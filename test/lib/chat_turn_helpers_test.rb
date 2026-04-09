# frozen_string_literal: true

require "test_helper"

# Verifies deterministic message selection for tool-using chat turns.
class ChatTurnHelpersTest < ActiveSupport::TestCase
  test "tool_turn_snapshot separates tool call result from final assistant reply" do
    user, workspace = create_user_with_workspace(
      email: "chat-turn-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Chat Turn"
    )

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "chat-turn-#{SecureRandom.hex(4)}",
        name: "Chat Turn",
        model_id: "gpt-5.4"
      )
      session = Session.resolve(agent:)

      session.messages.create!(role: "user", content: "Read the file")
      tool_call_message = session.messages.create!(role: "assistant", content: "")
      tool_call = tool_call_message.tool_calls.create!(
        tool_call_id: "call-#{SecureRandom.hex(4)}",
        name: "vault",
        arguments: { "action" => "read", "path" => "notes/manual.md" }
      )
      tool_result = session.messages.create!(
        role: "tool",
        content: "{\"content\":\"ember-otter\"}",
        tool_call_id: tool_call.id
      )
      final_assistant = session.messages.create!(role: "assistant", content: "ember-otter")

      snapshot = tool_turn_snapshot(
        messages: session.messages.includes(:tool_calls).order(:created_at, :id).to_a,
        tool_name: "vault"
      )

      assert_equal tool_call_message.id, snapshot[:assistant_with_tool]&.id
      assert_equal tool_call.id, snapshot[:tool_call]&.id
      assert_equal tool_result.id, snapshot[:tool_result]&.id
      assert_equal final_assistant.id, snapshot[:final_assistant]&.id
    end
  end
end
