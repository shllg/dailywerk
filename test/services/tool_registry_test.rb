# frozen_string_literal: true

require "test_helper"

class ToolRegistryTest < ActiveSupport::TestCase
  test "build instantiates only known tools" do
    user, workspace = create_user_with_workspace

    tools = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "tool-registry-#{SecureRandom.hex(4)}",
        name: "Tool Registry",
        model_id: "gpt-5.4"
      )
      session = Session.resolve(agent:)

      ToolRegistry.build([ "memory", "unknown", "vault" ], user:, session:)
    end

    assert_equal [ "MemoryTool", "VaultTool" ], tools.map { |tool| tool.class.name }
  end

  test "names returns the configured registry keys" do
    assert_equal %w[memory vault], ToolRegistry.names.sort
  end
end
