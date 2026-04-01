# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class Api::V1::ChatControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user, @workspace = create_user_with_workspace
    @agent = with_current_workspace(@workspace, user: @user) do
      Agent.create!(
        slug: "main",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        is_default: true
      )
    end
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "show returns the current session metadata and active message history" do
    session = with_current_workspace(@workspace, user: @user) do
      resolved_session = Session.resolve(agent: @agent)
      resolved_session.model.update!(context_window: 100)
      resolved_session.update!(summary: "Previous context")
      resolved_session.messages.create!(role: "user", content: "Hello")
      resolved_session.messages.create!(role: "assistant", content: "Hi there")
      resolved_session.messages.create!(role: "assistant", content: "Old summary detail", compacted: true)
      resolved_session
    end

    get "/api/v1/chat", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal(
      [ session.id, @agent.id, @agent.name, "Previous context", %w[user assistant] ],
      [
        body["session_id"],
        body.dig("agent", "id"),
        body.dig("agent", "name"),
        body["session_summary"],
        body["messages"].map { |message| message["role"] }
      ]
    )
    assert_in_delta 0.04, body["context_window_usage"]
  end

  test "create enqueues the stream job for a non-blank message" do
    assert_enqueued_with(job: ChatStreamJob) do
      post "/api/v1/chat",
           params: { message: { content: "Hello" } },
           as: :json,
           headers: api_auth_headers(user: @user, workspace: @workspace)
    end

    assert_response :accepted
  end

  test "create rejects blank messages" do
    assert_no_enqueued_jobs only: ChatStreamJob do
      post "/api/v1/chat",
           params: { message: { content: "   " } },
           as: :json,
           headers: api_auth_headers(user: @user, workspace: @workspace)
    end

    assert_response :unprocessable_entity
  end
end
