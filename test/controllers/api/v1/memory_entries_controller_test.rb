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
    create_memory_entry!(
      category: "preference",
      content: "User prefers concise answers.",
      importance: 7,
      confidence: 0.8
    )

    get "/api/v1/memory", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal 1, body["entries"].length
    assert_equal "preference", body["entries"].first["category"]
  end

  test "index lists active agent scopes" do
    get "/api/v1/memory", headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal @agent.id, body["agents"].first["id"]
  end

  test "create persists a private memory entry" do
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
    body = JSON.parse(response.body)

    assert_equal "private", body.dig("entry", "visibility")
    assert_equal @agent.id, body.dig("entry", "agent", "id")
  end

  test "update can move a private memory entry to shared scope" do
    entry = create_memory_entry!(
      agent: @agent,
      category: "preference",
      content: "User prefers detailed test output.",
      importance: 8,
      confidence: 0.9
    )

    patch "/api/v1/memory/#{entry.id}",
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
    body = JSON.parse(response.body)

    assert_equal "shared", body.dig("entry", "visibility")
    assert_nil body.dig("entry", "agent")
  end

  test "destroy deactivates a memory entry" do
    entry = create_memory_entry!(
      agent: @agent,
      category: "preference",
      content: "User prefers detailed test output.",
      importance: 8,
      confidence: 0.9
    )

    delete "/api/v1/memory/#{entry.id}",
           as: :json,
           headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    refute body.dig("entry", "active")
  end

  test "create rejects oversized metadata" do
    post "/api/v1/memory",
         params: {
           memory_entry: {
             content: "User prefers detailed test output.",
             category: "preference",
             importance: 8,
             confidence: 0.9,
             visibility: "shared",
             metadata: {
               notes: "x" * 11_000
             }
           }
         },
         as: :json,
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)

    assert_includes body["errors"], "Metadata must be 10 KB or smaller"
  end

  private

  def create_memory_entry!(attributes = {})
    with_current_workspace(@workspace, user: @user) do
      @workspace.memory_entries.create!(
        {
          category: "preference",
          content: "User prefers concise answers.",
          source: "manual",
          importance: 7,
          confidence: 0.8
        }.merge(attributes)
      )
    end
  end
end
