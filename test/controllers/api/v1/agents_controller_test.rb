# frozen_string_literal: true

require "test_helper"

class Api::V1::AgentsControllerTest < ActionDispatch::IntegrationTest
  setup do
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

  test "show returns the agent config and defaults" do
    get "/api/v1/agents/#{@agent.id}",
        headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success

    body = JSON.parse(response.body)

    assert_equal @agent.id, body.dig("agent", "id")
    assert_equal(
      [
        @agent.name,
        AgentDefaults::VALUES[:name],
        AgentDefaults::VALUES[:model_id]
      ],
      [
        body.dig("agent", "name"),
        body.dig("defaults", "name"),
        body.dig("defaults", "model_id")
      ]
    )
  end

  test "update persists allowed config fields" do
    patch "/api/v1/agents/#{@agent.id}",
          params: {
            agent: {
              name: "Operations",
              model_id: "claude-3-7-sonnet",
              provider: "anthropic",
              temperature: 0.4,
              instructions: "Answer directly.",
              soul: "Warm and rigorous.",
              identity: {
                persona: "Planner",
                tone: "Calm",
                constraints: "No fluff"
              },
              thinking: {
                enabled: true,
                budget_tokens: 2_500
              }
            }
          },
          as: :json,
          headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success

    @agent.reload

    assert_equal "Operations", @agent.name
    assert_equal(
      {
        model_id: "claude-3-7-sonnet",
        provider: "anthropic",
        temperature: 0.4,
        instructions: "Answer directly.",
        soul: "Warm and rigorous.",
        identity: {
          "persona" => "Planner",
          "tone" => "Calm",
          "constraints" => "No fluff"
        },
        thinking: {
          "enabled" => true,
          "budget_tokens" => 2_500
        }
      },
      {
        model_id: @agent.model_id,
        provider: @agent.provider,
        temperature: @agent.temperature,
        instructions: @agent.instructions,
        soul: @agent.soul,
        identity: @agent.identity,
        thinking: @agent.thinking
      }
    )
  end

  test "update rejects invalid config" do
    patch "/api/v1/agents/#{@agent.id}",
          params: {
            agent: {
              provider: "unsupported"
            }
          },
          as: :json,
          headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :unprocessable_entity

    body = JSON.parse(response.body)

    assert_includes body["errors"], "Provider is not included in the list"
  end

  test "update ignores unpermitted fields" do
    patch "/api/v1/agents/#{@agent.id}",
          params: {
            agent: {
              name: "Updated",
              active: false,
              is_default: false,
              params: {
                max_tokens: 512
              }
            }
          },
          as: :json,
          headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success

    @agent.reload

    assert_equal(
      {
        name: "Updated",
        active: true,
        is_default: true,
        params: { "max_tokens" => 512 }
      },
      {
        name: @agent.name,
        active: @agent.active,
        is_default: @agent.is_default,
        params: @agent.params
      }
    )
  end

  test "reset restores the factory defaults" do
    with_current_workspace(@workspace, user: @user) do
      @agent.update!(
        name: "Custom",
        model_id: "claude-3-7-sonnet",
        provider: "anthropic",
        instructions: "Custom prompt",
        soul: "Custom soul",
        temperature: 0.1,
        identity: {
          persona: "Planner"
        },
        thinking: {
          enabled: true,
          budget_tokens: 999
        }
      )
    end

    post "/api/v1/agents/#{@agent.id}/reset",
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success

    @agent.reload

    AgentDefaults.defaults.each do |field, value|
      actual = @agent.public_send(field)

      if value.nil?
        assert_nil actual
      else
        assert_equal value, actual
      end
    end
  end

  test "workspace isolation prevents accessing another workspace agent" do
    other_user, other_workspace = create_user_with_workspace(
      email: "other-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )

    other_agent = with_current_workspace(other_workspace, user: other_user) do
      Agent.create!(
        slug: "main",
        name: "Other",
        model_id: "gpt-5.4"
      )
    end

    get "/api/v1/agents/#{other_agent.id}",
        headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :not_found
  end
end
