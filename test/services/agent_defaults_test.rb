# frozen_string_literal: true

require "test_helper"

class AgentDefaultsTest < ActiveSupport::TestCase
  test "reset! restores the configurable fields" do
    user, workspace = create_user_with_workspace

    agent = with_current_workspace(workspace, user:) do
      Agent.create!(
        slug: "main",
        name: "Custom name",
        model_id: "claude-3-7-sonnet",
        provider: "anthropic",
        instructions: "Base instructions",
        soul: "Warm and precise",
        temperature: 0.2,
        identity: {
          persona: "Planner",
          tone: "Calm",
          constraints: "No filler"
        },
        params: {
          max_tokens: 512
        },
        thinking: {
          enabled: true,
          budget_tokens: 2_000
        }
      )
    end

    with_current_workspace(workspace, user:) do
      AgentDefaults.reset!(agent)
    end

    agent.reload

    AgentDefaults.defaults.each do |field, value|
      actual = agent.public_send(field)

      if value.nil?
        assert_nil actual
      else
        assert_equal value, actual
      end
    end
  end
end
