# frozen_string_literal: true

require "test_helper"

class ToolSchemaTest < ActiveSupport::TestCase
  FakeSession = Struct.new(:workspace, :agent, keyword_init: true)

  test "memory tool exposes a strict-compatible OpenAI schema" do
    definition = openai_tool_definition_for(MemoryTool)
    parameters = definition.dig(:function, :parameters)

    assert_equal true, definition.dig(:function, :strict)
    assert_equal false, parameters["additionalProperties"]
    assert_equal(
      parameters["properties"].keys.sort,
      parameters["required"].sort
    )
    assert_equal "null", parameters.dig("properties", "content", "anyOf", 1, "type")
  end

  test "vault tool exposes a strict-compatible OpenAI schema" do
    definition = openai_tool_definition_for(VaultTool)
    parameters = definition.dig(:function, :parameters)

    assert_equal true, definition.dig(:function, :strict)
    assert_equal false, parameters["additionalProperties"]
    assert_equal(
      parameters["properties"].keys.sort,
      parameters["required"].sort
    )
    assert_equal "null", parameters.dig("properties", "path", "anyOf", 1, "type")
  end

  private

  def openai_tool_definition_for(tool_class)
    user, workspace = create_user_with_workspace
    agent = Agent.new(
      workspace: workspace,
      slug: "tool-test-#{SecureRandom.hex(4)}",
      name: "Tool Test",
      model_id: "gpt-5.4"
    )
    session = FakeSession.new(workspace: workspace, agent: agent)

    RubyLLM::Providers::OpenAI::Tools.tool_for(tool_class.new(user:, session:))
  end
end
