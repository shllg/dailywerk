# frozen_string_literal: true

require "test_helper"

class AgentTest < ActiveSupport::TestCase
  setup do
    @user, @workspace = create_user_with_workspace
  end

  test "validates prompt field lengths" do
    with_current_workspace(@workspace, user: @user) do
      agent = build_agent(
        soul: "s" * 50_001,
        instructions: "i" * 50_001
      )

      assert_not agent.valid?
      assert_includes agent.errors[:soul], "is too long (maximum is 50000 characters)"
      assert_includes agent.errors[:instructions], "is too long (maximum is 50000 characters)"
    end
  end

  test "allows blank providers and rejects unknown providers" do
    with_current_workspace(@workspace, user: @user) do
      assert_equal [ true, true ], [
        build_agent(provider: nil).valid?,
        build_agent(provider: "").valid?
      ]

      agent = build_agent(provider: "mystery")

      assert_not agent.valid?
      assert_includes agent.errors[:provider], "is not included in the list"
    end
  end

  test "rejects unknown identity keys" do
    with_current_workspace(@workspace, user: @user) do
      agent = build_agent(identity: { persona: "Planner", examples: "Unsupported" })

      assert_not agent.valid?
      assert_includes agent.errors[:identity], "contains unknown keys: examples"
    end
  end

  test "rejects identity values that are not strings" do
    with_current_workspace(@workspace, user: @user) do
      agent = build_agent(identity: { persona: [ "Planner" ] })

      assert_not agent.valid?
      assert_includes agent.errors[:identity], "values must be strings"
    end
  end

  test "rejects identity values that exceed the length limit" do
    with_current_workspace(@workspace, user: @user) do
      agent = build_agent(identity: { persona: "p" * 20_001 })

      assert_not agent.valid?
      assert_includes agent.errors[:identity], "values must be 20000 characters or fewer"
    end
  end

  test "rejects invalid thinking config" do
    with_current_workspace(@workspace, user: @user) do
      agent = build_agent(
        thinking: {
          enabled: "yes",
          budget_tokens: 0,
          mode: "deep"
        }
      )

      assert_not agent.valid?
      assert_equal(
        [
          "contains unknown keys: mode",
          "enabled must be true or false",
          "budget_tokens must be an integer between 1 and 100,000"
        ],
        agent.errors[:thinking]
      )
    end
  end

  test "rejects params outside the allowlist and oversized params" do
    with_current_workspace(@workspace, user: @user) do
      oversized_stop = "x" * 10_500
      agent = build_agent(
        params: {
          compaction_model: "gpt-4o-mini",
          max_tokens: 512,
          session_timeout_hours: 4,
          unsupported: true,
          stop: oversized_stop
        }
      )

      assert_not agent.valid?
      assert_includes agent.errors[:params], "contains unknown keys: unsupported"
      assert_includes agent.errors[:params], "must be 10 KB or smaller"
    end
  end

  test "resolved_provider normalizes blank and present values" do
    assert_nil build_agent(provider: nil).resolved_provider
    assert_nil build_agent(provider: "").resolved_provider
    assert_equal :anthropic, build_agent(provider: "anthropic").resolved_provider
  end

  test "thinking_config returns a provider payload only when enabled" do
    disabled_agent = build_agent(thinking: { enabled: false })
    enabled_agent = build_agent(thinking: { enabled: true, budget_tokens: 3_000 })
    default_budget_agent = build_agent(thinking: { enabled: true })

    assert_equal({}, disabled_agent.thinking_config)
    assert_equal(
      { thinking: { budget_tokens: 3_000 } },
      enabled_agent.thinking_config
    )
    assert_equal(
      { thinking: { budget_tokens: Agent::DEFAULT_THINKING_BUDGET_TOKENS } },
      default_budget_agent.thinking_config
    )
  end

  private

  # @param attributes [Hash]
  # @return [Agent]
  def build_agent(attributes = {})
    Agent.new(
      {
        slug: "main-#{SecureRandom.hex(4)}",
        name: "DailyWerk",
        model_id: "gpt-5.4"
      }.merge(attributes)
    )
  end
end
