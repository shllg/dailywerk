# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
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
      assert_predicate first_session.started_at, :present?
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

  test "context_messages excludes compacted rows and to_llm replays only active messages" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      active_message = session.messages.create!(role: "user", content: "Keep me")
      session.messages.create!(role: "assistant", content: "Hide me", compacted: true)

      assert_equal [ active_message.id ], session.context_messages.pluck(:id)
      assert_equal [ "Keep me" ], session.to_llm.messages.map(&:content)
    end
  end

  test "active_context_tokens and estimated_context_tokens use active messages only" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      session.messages.create!(
        role: "user",
        content: "Compacted text",
        compacted: true,
        input_tokens: 999,
        output_tokens: 999
      )
      active_message = session.messages.create!(
        role: "assistant",
        content: "12345678",
        input_tokens: 12,
        output_tokens: 8
      )

      session.model.update!(context_window: 40)

      assert_equal 20, session.active_context_tokens
      assert_equal 2, session.estimated_context_tokens
      assert_in_delta 0.05, session.context_window_usage, 0.001
      assert_equal active_message.id, session.context_messages.last.id
    end
  end

  test "stale scope and stale? respect the inactivity threshold" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      stale_agent = Agent.create!(
        slug: "stale",
        name: "Stale",
        model_id: "gpt-5.4",
        params: { session_timeout_hours: 1 }
      )
      fresh_agent = Agent.create!(slug: "fresh", name: "Fresh", model_id: "gpt-5.4")
      stale_session = Session.resolve(agent: stale_agent)
      fresh_session = Session.resolve(agent: fresh_agent)

      stale_session.update!(last_activity_at: 2.hours.ago)
      fresh_session.update!(last_activity_at: 30.minutes.ago)

      assert_predicate stale_session, :stale?
      assert_not fresh_session.stale?
      assert_equal [ stale_session.id ], Session.stale(1.hour.ago).pluck(:id)
    end
  end

  test "archive! marks the session as archived and records the end time" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)

      session.archive!

      assert_equal "archived", session.status
      assert_predicate session.ended_at, :present?
    end
  end

  test "resolve rotates a stale session and inherits its summary" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "main",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        params: { session_timeout_hours: 1 }
      )
      original_session = Session.resolve(agent:)
      original_session.update!(
        summary: "Previous summary",
        last_activity_at: 2.hours.ago
      )

      rotated_session = Session.resolve(agent:)

      assert_not_equal original_session.id, rotated_session.id
      assert_equal "archived", original_session.reload.status
      assert_equal "Previous summary", rotated_session.summary
      assert_predicate rotated_session.started_at, :present?
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
