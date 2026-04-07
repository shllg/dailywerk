# frozen_string_literal: true

require "test_helper"

class SessionChannelTest < ActionCable::Channel::TestCase
  tests SessionChannel

  setup do
    @user, @workspace = create_user_with_workspace
    @session = with_current_workspace(@workspace, user: @user) do
      agent = Agent.create!(
        slug: "main-#{SecureRandom.hex(4)}",
        name: "DailyWerk",
        model_id: "gpt-5.4"
      )
      Session.resolve(agent:)
    end
  end

  test "subscribes to a session in the current workspace" do
    stub_connection current_user: @user, current_workspace: @workspace

    subscribe session_id: @session.id

    assert_predicate subscription, :confirmed?
    assert_has_stream "session_#{@session.id}"
  end

  test "rejects subscribing to a session from another workspace" do
    other_user, other_workspace = create_user_with_workspace(
      email: "session-channel-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )
    other_session = with_current_workspace(other_workspace, user: other_user) do
      agent = Agent.create!(
        slug: "main-#{SecureRandom.hex(4)}",
        name: "Other",
        model_id: "gpt-5.4"
      )
      Session.resolve(agent:)
    end

    stub_connection current_user: @user, current_workspace: @workspace

    subscribe session_id: other_session.id

    assert_predicate subscription, :rejected?
  end
end
