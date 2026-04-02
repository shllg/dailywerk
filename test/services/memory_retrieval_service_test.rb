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
        active: true
      )
      workspace.memory_entries.create!(
        workspace:,
        agent: primary_agent,
        category: "project",
        content: "Primary agent tracks the weekly tea planning context.",
        source: "manual",
        importance: 6,
        confidence: 0.8,
        active: true
      )
      workspace.memory_entries.create!(
        workspace:,
        agent: other_agent,
        category: "project",
        content: "Other agent private memory about tea.",
        source: "manual",
        importance: 10,
        confidence: 0.9,
        active: true
      )

      with_stubbed_ruby_llm_embed do
        MemoryRetrievalService.new(session:).build_context
      end
    end
  end
end
