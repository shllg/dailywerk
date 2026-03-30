# frozen_string_literal: true

# Stores tool call metadata for a message, even when tools are disabled.
class ToolCall < ApplicationRecord
  acts_as_tool_call message: :message
end
