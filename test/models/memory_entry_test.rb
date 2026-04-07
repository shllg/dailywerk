# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class MemoryEntryTest < ActiveSupport::TestCase
  test "fingerprint_for normalizes whitespace and case" do
    first = MemoryEntry.fingerprint_for(
      category: "Preference",
      content: "User likes tea"
    )
    second = MemoryEntry.fingerprint_for(
      category: "preference",
      content: "  user   likes   tea "
    )

    assert_equal first, second
  end

  test "assigns a fingerprint and rejects oversized metadata" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      entry = MemoryEntry.create!(
        category: "fact",
        content: "Remember the quarterly review",
        source: "manual",
        importance: 6,
        confidence: 0.8
      )
      oversized = MemoryEntry.new(
        category: "fact",
        content: "Oversized metadata",
        source: "manual",
        importance: 6,
        confidence: 0.8,
        metadata: { "blob" => "x" * 10_500 }
      )

      assert_predicate entry.fingerprint, :present?
      assert_not oversized.valid?
      assert_includes oversized.errors[:metadata], "must be 10 KB or smaller"
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
