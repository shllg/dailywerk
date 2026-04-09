# frozen_string_literal: true

# Resolves persisted messages for one chat turn in tool-using conversations.
module ChatTurnHelpers
  # Identifies the assistant tool-call message, its tool result, and the final
  # assistant reply from an ordered list of newly-created turn messages.
  #
  # @param messages [Array<Message>]
  # @param tool_name [String]
  # @return [Hash]
  def tool_turn_snapshot(messages:, tool_name:)
    assistant_with_tool = messages.find do |message|
      message.role == "assistant" && message.tool_calls.any? { |tool_call| tool_call.name == tool_name }
    end
    tool_call = assistant_with_tool&.tool_calls&.find { |call| call.name == tool_name }
    tool_result = messages.find { |message| message.tool_call_id == tool_call&.id }
    final_assistant = messages.reverse.find do |message|
      message.role == "assistant" && message.tool_calls.empty?
    end

    {
      assistant_with_tool: assistant_with_tool,
      tool_call: tool_call,
      tool_result: tool_result,
      final_assistant: final_assistant
    }
  end
end
