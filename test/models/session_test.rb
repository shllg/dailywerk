# frozen_string_literal: true

require "test_helper"

class SessionTest < ActiveSupport::TestCase
  test "resolve reuses the active session for the same agent and gateway" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "main",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        is_default: true
      )

      first_session = Session.resolve(agent:)
      second_session = Session.resolve(agent:)

      assert_equal first_session, second_session
      assert_equal 1, Session.count
      assert_equal "web", first_session.gateway
    end
  end

  test "resolve stores the model record with the agent provider" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "main",
        name: "Claude",
        model_id: "claude-3-7-sonnet",
        provider: "anthropic"
      )

      session = Session.resolve(agent:)

      assert_equal "anthropic", session.model.provider
      assert_equal "claude-3-7-sonnet", session.model.model_id
    end
  end

  test "rejects agents from another workspace" do
    user, workspace = create_user_with_workspace
    other_user, other_workspace = create_user_with_workspace(
      email: "other-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )

    other_agent = with_current_workspace(other_workspace, user: other_user) do
      Agent.create!(slug: "main", name: "Other", model_id: "gpt-5.4")
    end

    invalid_session = with_current_workspace(workspace, user:) do
      Session.new(agent: other_agent, workspace:, gateway: "web", status: "active")
    end

    assert_not invalid_session.valid?
    assert_includes invalid_session.errors[:agent], "must belong to the current workspace"
  end
end
