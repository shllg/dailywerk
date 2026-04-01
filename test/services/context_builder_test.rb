# frozen_string_literal: true

require "test_helper"

class ContextBuilderTest < ActiveSupport::TestCase
  test "build returns the prompt and metadata without summary" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "main",
        name: "DailyWerk",
        model_id: "gpt-5.4",
        instructions: "Be concise."
      )
      session = Session.resolve(agent:)

      payload = ContextBuilder.new(session:).build

      assert_equal "Be concise.", payload[:system_prompt]
      assert_equal 0, payload[:active_message_count]
      assert_equal 0, payload[:estimated_tokens]
    end
  end

  test "build includes the inherited summary" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      session.update!(summary: "Earlier discussion")

      payload = ContextBuilder.new(session:).build

      assert_includes payload[:system_prompt], "## Previous Context\n\nEarlier discussion"
    end
  end

  test "build includes summarized bridge messages for a fresh session" do
    user, workspace = create_user_with_workspace
    original_call = MessageSummarizer.method(:call)

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      previous_session = Session.resolve(agent:)
      previous_session.messages.create!(role: "user", content: "Very long prior message")
      previous_session.messages.create!(role: "assistant", content: "Prior reply")
      previous_session.archive!

      current_session = Session.resolve(agent:)
      MessageSummarizer.define_singleton_method(:call) do |text, model:|
        "#{model}: #{text.to_s.upcase}"
      end

      payload = ContextBuilder.new(session: current_session).build

      assert_includes payload[:system_prompt], "## Recent Messages (from previous session)"
      assert_includes payload[:system_prompt], "[user] gpt-5.4: VERY LONG PRIOR MESSAGE"
      assert_includes payload[:system_prompt], "[assistant] gpt-5.4: PRIOR REPLY"
    end
  ensure
    MessageSummarizer.define_singleton_method(:call, original_call)
  end

  test "build skips bridge messages once the current session has content" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      previous_session = Session.resolve(agent:)
      previous_session.messages.create!(role: "user", content: "Earlier message")
      previous_session.archive!

      current_session = Session.resolve(agent:)
      current_session.messages.create!(role: "user", content: "Current message")

      payload = ContextBuilder.new(session: current_session).build

      assert_equal 1, payload[:active_message_count]
      assert_not_includes payload[:system_prompt], "## Recent Messages (from previous session)"
    end
  end
end
