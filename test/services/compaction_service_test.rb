# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class CompactionServiceTest < ActiveSupport::TestCase
  test "compact! skips sessions with too few non-system messages" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      session = create_session_for_tests
      9.times { |index| session.messages.create!(role: "user", content: "Message #{index}") }
      4.times { |index| session.messages.create!(role: "system", content: "System #{index}") }

      result = CompactionService.new(session).compact!

      refute result[:compacted]
      assert_equal "too_few_messages", result[:reason]
      assert_equal 0, session.messages.compacted.count
    end
  end

  test "compact! marks older messages and appends to the summary" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      session = create_session_for_tests(summary: "Earlier summary")
      12.times { |index| session.messages.create!(role: "user", content: "Message #{index}") }
      service = CompactionService.new(session)
      captured_messages_length = nil
      captured_preserved_facts = nil
      service.define_singleton_method(:generate_summary) do |messages, preserved_facts|
        captured_messages_length = messages.length
        captured_preserved_facts = preserved_facts
        "New summary"
      end

      result = service.compact!

      assert result[:compacted]
      assert_equal 2, result[:messages_compacted]
      assert_equal 2, captured_messages_length
      assert_equal "", captured_preserved_facts
      assert_equal 2, session.messages.compacted.count
      assert_equal "Earlier summary\n\n---\n\nNew summary", session.reload.summary
    end
  end

  test "compact! excludes system messages from summarization and compaction" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      session = create_session_for_tests
      system_message = session.messages.create!(role: "system", content: "System prompt")
      11.times { |index| session.messages.create!(role: "user", content: "Message #{index}") }
      service = CompactionService.new(session)
      captured_roles = nil
      service.define_singleton_method(:generate_summary) do |messages, _preserved_facts|
        captured_roles = messages.map(&:role)
        "New summary"
      end

      service.compact!

      assert_equal [ "user" ], captured_roles.uniq
      assert_not system_message.reload.compacted
    end
  end

  test "compact! rewrites the summary when it exceeds the token threshold" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      long_summary = "Previous context. " * 1000
      session = create_session_for_tests(summary: long_summary)
      12.times { |index| session.messages.create!(role: "user", content: "Message #{index}") }

      service = CompactionService.new(session)
      service.define_singleton_method(:generate_summary) do |messages, _preserved_facts|
        "New compacted summary"
      end
      service.define_singleton_method(:rewrite_summary) do |old_summary, new_summary|
        "Rewritten: combined summary"
      end

      result = service.compact!

      assert result[:compacted]
      assert_equal "Rewritten: combined summary", session.reload.summary
    end
  end

  test "compact! appends summary when under threshold" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      session = create_session_for_tests(summary: "Short prior summary")
      12.times { |index| session.messages.create!(role: "user", content: "Message #{index}") }

      service = CompactionService.new(session)
      service.define_singleton_method(:generate_summary) do |messages, _preserved_facts|
        "New summary"
      end

      result = service.compact!

      assert result[:compacted]
      assert_equal "Short prior summary\n\n---\n\nNew summary", session.reload.summary
    end
  end

  private

  # @param summary [String, nil]
  # @return [Session]
  def create_session_for_tests(summary: nil)
    agent = Agent.create!(slug: "main-#{SecureRandom.hex(4)}", name: "DailyWerk", model_id: "gpt-5.4")
    Session.resolve(agent:).tap do |session|
      session.update!(summary:) if summary
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
