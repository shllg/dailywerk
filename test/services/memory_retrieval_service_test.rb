# frozen_string_literal: true

require "test_helper"

class MemoryRetrievalServiceTest < ActiveSupport::TestCase
  test "build_context returns only shared and same-agent memories" do
    payload = build_context_for_shared_and_agent_memories
    memory_contents = payload[:memories].map(&:content)

    assert_includes memory_contents, "User prefers tea over coffee."
    assert_includes memory_contents, "Primary agent tracks the weekly tea planning context."
    refute_includes memory_contents, "Other agent private memory about tea."
  end

  test "build_context marks returned memories as accessed" do
    payload = build_context_for_shared_and_agent_memories

    assert_equal 2, payload[:memories].size
    assert payload[:memories].all? { |entry| entry.reload.access_count.positive? }
  end

  test "archived_scope includes other agents for shared isolation" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent_a = Agent.create!(
        slug: "a-#{SecureRandom.hex(4)}",
        name: "Agent A",
        model_id: "gpt-5.4",
        memory_isolation: "shared"
      )
      agent_b = Agent.create!(
        slug: "b-#{SecureRandom.hex(4)}",
        name: "Agent B",
        model_id: "gpt-5.4",
        memory_isolation: "shared"
      )

      session_b = Session.resolve(agent: agent_b)
      session_b.archive!
      ConversationArchive.create!(
        session: session_b,
        workspace:,
        agent: agent_b,
        summary: "Conversation with Agent B",
        started_at: 1.hour.ago,
        ended_at: Time.current
      )

      session_a = Session.resolve(agent: agent_a)
      session_a.messages.create!(role: "user", content: "Hello Agent A")

      service = MemoryRetrievalService.new(session: session_a)
      scope = service.send(:archived_scope)

      assert_predicate scope, :exists?, "Shared agent should see archives from other agents"
    end
  end

  test "archived_scope excludes other agents for isolated isolation" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent_a = Agent.create!(
        slug: "a-#{SecureRandom.hex(4)}",
        name: "Agent A",
        model_id: "gpt-5.4",
        memory_isolation: "isolated"
      )
      agent_b = Agent.create!(
        slug: "b-#{SecureRandom.hex(4)}",
        name: "Agent B",
        model_id: "gpt-5.4",
        memory_isolation: "isolated"
      )

      session_b = Session.resolve(agent: agent_b)
      session_b.archive!
      ConversationArchive.create!(
        session: session_b,
        workspace:,
        agent: agent_b,
        summary: "Conversation with Agent B",
        started_at: 1.hour.ago,
        ended_at: Time.current
      )

      session_a = Session.resolve(agent: agent_a)
      session_a.messages.create!(role: "user", content: "Hello Agent A")

      service = MemoryRetrievalService.new(session: session_a)
      scope = service.send(:archived_scope)

      assert_not scope.exists?, "Isolated agent should not see archives from other agents"
    end
  end

  private

  def build_context_for_shared_and_agent_memories
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      primary_agent = Agent.create!(
        slug: "main",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        memory_isolation: "shared"
      )
      other_agent = Agent.create!(
        slug: "other-#{SecureRandom.hex(4)}",
        name: "Other",
        model_id: "gpt-5.4",
        memory_isolation: "shared"
      )
      session = Session.resolve(agent: primary_agent)
      session.messages.create!(role: "user", content: "Please remember that I prefer tea.")

      workspace.memory_entries.create!(
        workspace:,
        category: "preference",
        content: "User prefers tea over coffee.",
        source: "manual",
        importance: 8,
        confidence: 0.9,
        active: true,
        staged: false
      )
      workspace.memory_entries.create!(
        workspace:,
        agent: primary_agent,
        category: "project",
        content: "Primary agent tracks the weekly tea planning context.",
        source: "manual",
        importance: 6,
        confidence: 0.8,
        active: true,
        staged: false
      )
      workspace.memory_entries.create!(
        workspace:,
        agent: other_agent,
        category: "project",
        content: "Other agent private memory about tea.",
        source: "manual",
        importance: 10,
        confidence: 0.9,
        active: true,
        staged: false
      )

      with_stubbed_ruby_llm_embed do
        MemoryRetrievalService.new(session:).build_context
      end
    end
  end
end
