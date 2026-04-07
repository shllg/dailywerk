# frozen_string_literal: true

require "test_helper"

class ChatStreamJobTest < ActiveSupport::TestCase
  test "broadcasts streaming events and updates session counters" do
    user, workspace = create_user_with_workspace

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "main",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        is_default: true
      )
      Session.resolve(agent:)
    end

    fake_service = Object.new
    fake_service.define_singleton_method(:call) do |_user_message, &block|
      session.messages.create!(role: "user", content: "Hello")
      assistant = session.messages.create!(role: "assistant", content: "")
      block.call(Struct.new(:content).new("Hi"))
      assistant.update!(content: "Hi there", input_tokens: 3, output_tokens: 5)
      assistant
    end

    broadcasts = []
    original_new = AgentRuntime.method(:new)
    server = ActionCable.server
    original_broadcast = server.method(:broadcast)

    begin
      AgentRuntime.define_singleton_method(:new) do |session:|
        fake_service
      end
      server.define_singleton_method(:broadcast) do |stream, payload|
        broadcasts << [ stream, payload ]
      end

      ChatStreamJob.perform_now(session.id, "Hello", workspace_id: workspace.id)
    ensure
      AgentRuntime.define_singleton_method(:new, original_new)
      server.define_singleton_method(:broadcast, original_broadcast)
    end

    session.reload
    assistant_message_id = with_current_workspace(workspace, user:) do
      session.messages.where(role: "assistant").pick(:id)
    end

    assert_equal [ 2, 8 ], [ session.message_count, session.total_tokens ]
    assert_in_delta Time.current.to_f, session.last_activity_at.to_f, 5
    assert_equal(
      [
        [
          "session_#{session.id}",
          {
            type: "token",
            delta: "Hi",
            message_id: assistant_message_id
          }
        ],
        [
          "session_#{session.id}",
          {
            type: "complete",
            content: "Hi there",
            message_id: assistant_message_id
          }
        ]
      ],
      broadcasts
    )
  end

  test "broadcasts an error and re-raises runtime failures" do
    user, workspace = create_user_with_workspace(
      email: "chat-job-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Chat Job"
    )

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "main-#{SecureRandom.hex(4)}",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        is_default: true
      )
      Session.resolve(agent:)
    end

    fake_service = Object.new
    fake_service.define_singleton_method(:call) do |_user_message, &_block|
      raise "stream failed"
    end

    broadcasts = []
    original_new = AgentRuntime.method(:new)
    server = ActionCable.server
    original_broadcast = server.method(:broadcast)

    error = begin
      AgentRuntime.define_singleton_method(:new) do |session:|
        fake_service
      end
      server.define_singleton_method(:broadcast) do |stream, payload|
        broadcasts << [ stream, payload ]
      end

      assert_raises(RuntimeError) do
        ChatStreamJob.perform_now(session.id, "Hello", workspace_id: workspace.id)
      end
    ensure
      AgentRuntime.define_singleton_method(:new, original_new)
      server.define_singleton_method(:broadcast, original_broadcast)
    end

    assert_equal "stream failed", error.message
    assert_equal(
      [
        [
          "session_#{session.id}",
          {
            type: "error",
            message: "Something went wrong. Please try again."
          }
        ]
      ],
      broadcasts
    )
  end
end
