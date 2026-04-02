# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class MemoryManagerTest < ActiveSupport::TestCase
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

  test "store reuses the existing shared memory entry" do
    with_shared_memory_stored_twice do |first_entry, second_entry|
      assert_equal first_entry.id, second_entry.id
      assert_nil second_entry.agent_id
    end
  end

  test "store refreshes the shared memory attributes and audit history" do
    with_shared_memory_stored_twice do |_, second_entry|
      assert_equal 9, second_entry.importance
      assert_in_delta(0.9, second_entry.confidence.to_f)
      assert_equal 2, second_entry.versions.count
    end
  end

  test "store creates a private memory when requested" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "research-#{SecureRandom.hex(4)}",
        name: "Research",
        model_id: "gpt-5.4",
        memory_isolation: "read_shared"
      )
      session = Session.resolve(agent:)
      manager = MemoryManager.new(
        workspace:,
        actor_user: user,
        actor_agent: agent,
        session:
      )

      entry = manager.store(
        content: "The research agent tracks competitor pricing separately.",
        category: "project",
        importance: 6,
        confidence: 0.75,
        visibility: "private",
        source: "tool"
      )

      assert_equal agent.id, entry.agent_id
      assert_equal "private", entry.scope_label
      assert_equal "tool", entry.source
    end
  end

  private

  def with_shared_memory_stored_twice
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      manager = MemoryManager.new(
        workspace:,
        actor_user: user,
        actor_agent: agent,
        session:
      )

      first_entry = manager.store(
        content: "User prefers concise answers.",
        category: "preference",
        importance: 7,
        confidence: 0.8,
        visibility: "shared",
        source: "manual"
      )
      second_entry = manager.store(
        content: "User prefers concise answers.",
        category: "preference",
        importance: 9,
        confidence: 0.9,
        visibility: "shared",
        source: "manual"
      )

      yield first_entry, second_entry
    end
  end
end
