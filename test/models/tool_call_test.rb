# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class ToolCallTest < ActiveSupport::TestCase
  test "parses tool errors and resolves the linked result message" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "tool-call-#{SecureRandom.hex(4)}",
        name: "Tool Call",
        model_id: "gpt-5.4"
      )
      session = Session.resolve(agent:)
      message = session.messages.create!(role: "assistant", content: "")
      tool_call = message.tool_calls.create!(
        tool_call_id: "call-1",
        name: "memory",
        arguments: { "error" => "memory unavailable" }
      )
      result = session.messages.create!(
        role: "system",
        content: "Tool failed",
        tool_call_id: tool_call.id
      )

      assert_equal "memory unavailable", tool_call.tool_error_message
      assert_equal message.id, tool_call.message.id
      assert_equal result.id, tool_call.result.id
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
