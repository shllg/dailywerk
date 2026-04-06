# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class MemoryConsolidationServiceTest < ActiveSupport::TestCase
  test "promotes staged memories without near-duplicates" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      Agent.create!(slug: "main-#{SecureRandom.hex(4)}", name: "DailyWerk", model_id: "gpt-5.4")
      entry = workspace.memory_entries.create!(
        category: "fact",
        content: "User prefers dark mode.",
        source: "extraction",
        importance: 6,
        confidence: 0.8,
        staged: true
      )

      stats = MemoryConsolidationService.new(workspace:).call

      assert_equal 1, stats[:promoted]
      assert_not entry.reload.staged
      assert_not_nil entry.promoted_at
    end
  end

  test "discards staged memories that are near-duplicates of promoted ones" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      Agent.create!(slug: "main-#{SecureRandom.hex(4)}", name: "DailyWerk", model_id: "gpt-5.4")
      embedding = Array.new(1536, 0.1)

      workspace.memory_entries.create!(
        category: "preference",
        content: "User likes dark themes.",
        source: "manual",
        importance: 7,
        confidence: 0.9,
        staged: false,
        promoted_at: 1.day.ago,
        embedding: embedding
      )
      candidate = workspace.memory_entries.create!(
        category: "preference",
        content: "User prefers dark themes.",
        source: "extraction",
        importance: 5,
        confidence: 0.7,
        staged: true,
        embedding: embedding
      )

      stats = MemoryConsolidationService.new(workspace:).call

      assert_equal 1, stats[:discarded]
      assert_not candidate.reload.active?
    end
  end

  test "applies recency decay to unaccessed promoted memories" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      Agent.create!(slug: "main-#{SecureRandom.hex(4)}", name: "DailyWerk", model_id: "gpt-5.4")
      entry = workspace.memory_entries.create!(
        category: "fact",
        content: "User works at Acme Corp.",
        source: "extraction",
        importance: 5,
        confidence: 0.8,
        staged: false,
        promoted_at: 60.days.ago,
        last_accessed_at: 45.days.ago
      )

      stats = MemoryConsolidationService.new(workspace:).call

      assert_operator stats[:decayed], :>=, 1
      assert_equal 4, entry.reload.importance
    end
  end

  test "does not decay memories at minimum importance" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      Agent.create!(slug: "main-#{SecureRandom.hex(4)}", name: "DailyWerk", model_id: "gpt-5.4")
      entry = workspace.memory_entries.create!(
        category: "fact",
        content: "Minimum importance memory.",
        source: "extraction",
        importance: 1,
        confidence: 0.5,
        staged: false,
        promoted_at: 60.days.ago,
        last_accessed_at: nil
      )

      MemoryConsolidationService.new(workspace:).call

      assert_equal 1, entry.reload.importance
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
