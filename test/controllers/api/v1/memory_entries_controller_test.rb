# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class Api::V1::MemoryEntriesControllerTest < ActionDispatch::IntegrationTest
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

  test "index lists workspace memory entries" do
    with_current_workspace(@workspace, user: @user) do
      @workspace.memory_entries.create!(
        workspace: @workspace,
        category: "preference",
        content: "User prefers concise answers.",
        source: "manual",
        importance: 7,
        confidence: 0.8
      )
    end

    get "/api/v1/memory", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal 1, body["entries"].length
    assert_equal "preference", body["entries"].first["category"]
    assert_equal @agent.id, body["agents"].first["id"]
  end

  test "create update and destroy manage structured memory entries" do
    post "/api/v1/memory",
         params: {
           memory_entry: {
             content: "User prefers detailed test output.",
             category: "preference",
             importance: 8,
             confidence: 0.9,
             visibility: "private",
             agent_id: @agent.id
           }
         },
         as: :json,
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :created
    created_body = JSON.parse(response.body)
    created_id = created_body.dig("entry", "id")
    assert_equal "private", created_body.dig("entry", "visibility")

    patch "/api/v1/memory/#{created_id}",
          params: {
            memory_entry: {
              content: "User prefers detailed test output with file references.",
              category: "instruction",
              importance: 9,
              confidence: 0.95,
              visibility: "shared"
            }
          },
          as: :json,
          headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    updated_body = JSON.parse(response.body)
    assert_equal "shared", updated_body.dig("entry", "visibility")
    assert_nil updated_body.dig("entry", "agent")

    delete "/api/v1/memory/#{created_id}",
           as: :json,
           headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    destroyed_body = JSON.parse(response.body)
    assert_equal false, destroyed_body.dig("entry", "active")
  end
end
