# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class MemoryExtractionServiceTest < ActiveSupport::TestCase
  test "normalizes extracted memories and fills in defaults" do
    user, workspace = create_user_with_workspace

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "memory-extract-#{SecureRandom.hex(4)}",
        name: "Extractor",
        model_id: "gpt-5.4",
        memory_isolation: "isolated"
      )
      Session.resolve(agent:)
    end

    fake_chat = Object.new
    original_chat = RubyLLM.method(:chat)

    fake_chat.define_singleton_method(:with_temperature) do |_temperature|
      self
    end
    fake_chat.define_singleton_method(:with_schema) do |schema|
      raise "unexpected schema" unless schema == MemoryExtractionService::MEMORY_SCHEMA

      self
    end
    fake_chat.define_singleton_method(:ask) do |_prompt|
      Struct.new(:content, keyword_init: true).new(
        content: {
          "memories" => [
            {
              "content" => "  User likes tea  ",
              "category" => "preference",
              "importance" => 15,
              "confidence" => 1.7,
              "visibility" => ""
            },
            {
              "content" => "   ",
              "category" => "fact",
              "importance" => 1,
              "confidence" => 0.2,
              "visibility" => "shared"
            }
          ]
        }
      )
    end

    RubyLLM.define_singleton_method(:chat) do |model:|
      raise "unexpected model" unless model == "gpt-5.4"

      fake_chat
    end

    memories = MemoryExtractionService.new(session:).extract("Conversation transcript")

    assert_equal 1, memories.length
    assert_equal(
      {
        content: "User likes tea",
        category: "preference",
        importance: 10,
        confidence: 1.0,
        visibility: "private"
      },
      memories.first
    )
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat)
  end

  test "returns an empty list when extraction fails" do
    user, workspace = create_user_with_workspace(
      email: "memory-extraction-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Memory Extraction"
    )

    session = with_current_workspace(workspace, user:) do
      agent = Agent.create!(
        slug: "extract-failure-#{SecureRandom.hex(4)}",
        name: "Failure",
        model_id: "gpt-5.4"
      )
      Session.resolve(agent:)
    end

    original_chat = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) do |**_kwargs|
      raise "provider error"
    end

    result = silence_expected_logs do
      MemoryExtractionService.new(session:).extract("Something important")
    end

    assert_equal [], result
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat)
  end
end
# rubocop:enable Minitest/MultipleAssertions
