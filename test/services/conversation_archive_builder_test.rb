# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class ConversationArchiveBuilderTest < ActiveSupport::TestCase
  test "reuses the persisted session summary and extracts key facts" do
    user, workspace = create_user_with_workspace

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "archive-builder-#{SecureRandom.hex(4)}",
        name: "Archive Builder",
        model_id: "gpt-5.4"
      )
      created_session = Session.resolve(agent:)
      created_session.update!(summary: "Persisted summary")
      created_session
    end

    original_constructor = MemoryExtractionService.method(:new)
    fake_extractor_class = Struct.new(:memories) do
      def extract(_transcript)
        memories
      end
    end

    target_session_id = session.id

    MemoryExtractionService.define_singleton_method(:new) do |session:|
      raise "unexpected summary" unless session.summary == "Persisted summary"
      raise "unexpected session" unless session.id == target_session_id

      fake_extractor_class.new([ { content: "Prefers concise answers." } ])
    end

    payload = with_current_workspace(workspace, user:) do
      ConversationArchiveBuilder.new(session).build
    end

    assert_equal "Persisted summary", payload[:summary]
    assert_equal [ "Prefers concise answers." ], payload[:key_facts]
  ensure
    MemoryExtractionService.define_singleton_method(:new, original_constructor)
  end

  test "summarizes recent messages when the session summary is blank" do
    user, workspace = create_user_with_workspace(
      email: "archive-builder-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Archive Builder"
    )

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "archive-#{SecureRandom.hex(4)}",
        name: "Archive",
        model_id: "gpt-5.4"
      )
      created_session = Session.resolve(agent:)
      created_session.messages.create!(role: "user", content: "How should we stage the launch?")
      created_session.messages.create!(role: "assistant", content: "Start with the internal rollout checklist.")
      created_session
    end

    original_batch_call = MessageSummarizer.method(:batch_call)
    original_chat = RubyLLM.method(:chat)
    original_extractor = MemoryExtractionService.method(:new)
    fake_chat = Object.new
    target_session_id = session.id

    MessageSummarizer.define_singleton_method(:batch_call) do |texts, model:|
      raise "unexpected model" unless model == "gpt-5.4"
      raise "unexpected text count" unless texts.length == 2

      [ "Launch question", "Rollout answer" ]
    end

    fake_chat.define_singleton_method(:with_temperature) do |_temperature|
      self
    end
    fake_chat.define_singleton_method(:ask) do |_prompt|
      Struct.new(:content).new("Condensed archive summary")
    end
    RubyLLM.define_singleton_method(:chat) do |model:|
      raise "unexpected model" unless model == "gpt-5.4"

      fake_chat
    end

    MemoryExtractionService.define_singleton_method(:new) do |session:|
      raise "unexpected session" unless session.id == target_session_id

      Struct.new(:memories) do
        def extract(_transcript)
          memories
        end
      end.new([])
    end

    payload = with_current_workspace(workspace, user:) do
      ConversationArchiveBuilder.new(session).build
    end

    assert_equal "Condensed archive summary", payload[:summary]
    assert_equal [], payload[:key_facts]
  ensure
    MessageSummarizer.define_singleton_method(:batch_call, original_batch_call)
    RubyLLM.define_singleton_method(:chat, original_chat)
    MemoryExtractionService.define_singleton_method(:new, original_extractor)
  end
end
# rubocop:enable Minitest/MultipleAssertions
