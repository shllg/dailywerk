# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

# rubocop:disable Minitest/MultipleAssertions
class MemoryToolTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "store creates a private memory for isolated agents" do
    user, workspace, session, tool = build_tool(memory_isolation: "isolated")
    result = nil

    assert_enqueued_jobs 1, only: GenerateEmbeddingJob do
      result = with_current_workspace(workspace, user:) do
        tool.execute(
          action: "store",
          content: "Remember tea",
          category: "preference",
          importance: 8,
          confidence: 0.9
        )
      end
    end

    assert_equal "Remember tea", result[:content]
    assert_equal "preference", result[:category]
    assert_equal "private", result[:visibility]
    assert_equal session.agent_id, result[:agent_id]
  end

  test "list only returns active memories in the current tool scope" do
    user, workspace, session, tool = build_tool(memory_isolation: "isolated")
    visible = create_memory!(workspace:, session:, content: "Visible memory", agent: session.agent)
    create_memory!(workspace:, session:, content: "Shared memory", agent: nil)
    create_memory!(workspace:, session:, content: "Inactive memory", agent: session.agent, active: false)

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "list")
    end

    assert_equal [ visible.id ], result.map { |entry| entry[:id] }
    assert_equal [ "Visible memory" ], result.map { |entry| entry[:content] }
  end

  test "recall returns ranked memories from the retrieval service" do
    user, workspace, session, tool = build_tool(memory_isolation: "shared")
    entry = create_memory!(workspace:, session:, content: "Prefers oolong", agent: nil)
    session_record = session
    fake_service = Object.new
    original_new = MemoryRetrievalService.method(:new)

    fake_service.define_singleton_method(:send) do |method_name, relation, query|
      raise "unexpected method" unless method_name == :rank_candidates
      raise "unexpected relation" unless relation.is_a?(ActiveRecord::Relation)
      raise "unexpected query" unless query == "oolong"

      [ entry ]
    end

    MemoryRetrievalService.define_singleton_method(:new) do |session:|
      raise "unexpected session" unless session == session_record

      fake_service
    end

    result = with_current_workspace(workspace, user:) do
      tool.execute(action: "recall", query: "oolong")
    end

    assert_equal [ entry.id ], result.map { |memory| memory[:id] }
    assert_equal [ "Prefers oolong" ], result.map { |memory| memory[:content] }
  ensure
    MemoryRetrievalService.define_singleton_method(:new, original_new)
  end

  test "update and forget change the targeted memory" do
    user, workspace, session, tool = build_tool(memory_isolation: "shared")
    entry = create_memory!(workspace:, session:, content: "Remember tea", agent: session.agent)

    updated = with_current_workspace(workspace, user:) do
      tool.execute(
        action: "update",
        memory_id: entry.id,
        content: "Remember coffee",
        category: "preference",
        importance: 7,
        confidence: 0.8,
        visibility: "shared"
      )
    end

    forgotten = with_current_workspace(workspace, user:) do
      tool.execute(action: "forget", memory_id: entry.id)
    end

    assert_equal "Remember coffee", updated[:content]
    assert_equal "preference", updated[:category]
    assert_equal "shared", updated[:visibility]
    assert_nil updated[:agent_id]
    refute forgotten[:active]
  end

  private

  def build_tool(memory_isolation:)
    user, workspace = create_user_with_workspace(
      email: "memory-tool-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Memory Tool"
    )

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "memory-tool-#{SecureRandom.hex(4)}",
        name: "Memory Tool",
        model_id: "gpt-5.4",
        memory_isolation: memory_isolation
      )
      Session.resolve(agent:)
    end

    [ user, workspace, session, MemoryTool.new(user:, session:) ]
  end

  def create_memory!(workspace:, session:, content:, agent:, active: true, category: "fact")
    with_current_workspace(workspace, user: session.workspace.owner) do
      MemoryEntry.create!(
        workspace: workspace,
        agent: agent,
        session: session,
        category: category,
        content: content,
        source: "tool",
        importance: 5,
        confidence: 0.7,
        fingerprint: MemoryEntry.fingerprint_for(category: category, content: content),
        active: active
      )
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
