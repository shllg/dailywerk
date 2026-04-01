# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class MessageSummarizerTest < ActiveSupport::TestCase
  test "returns short text unchanged" do
    assert_equal "short text", MessageSummarizer.call("short text")
  end

  test "returns blank text unchanged" do
    assert_equal "", MessageSummarizer.call(nil)
  end

  test "summarizes long text through ruby_llm" do
    models = []
    temperatures = []
    prompts = []
    fake_chat = Object.new
    original_chat = RubyLLM.method(:chat)

    fake_chat.define_singleton_method(:with_temperature) do |temperature|
      temperatures << temperature
      self
    end
    fake_chat.define_singleton_method(:ask) do |prompt|
      prompts << prompt
      Struct.new(:content).new("condensed")
    end

    RubyLLM.define_singleton_method(:chat) do |model:|
      models << model
      fake_chat
    end

    text = "x" * 600
    result = MessageSummarizer.call(text, model: "claude-3-7-sonnet")

    assert_equal "condensed", result
    assert_equal [ "claude-3-7-sonnet" ], models
    assert_equal [ 0.1 ], temperatures
    assert_match(/Condense this message/, prompts.first)
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat)
  end

  test "falls back to truncation when summarization fails" do
    original_chat = RubyLLM.method(:chat)

    RubyLLM.define_singleton_method(:chat) do |model:|
      raise "boom"
    end

    text = "x" * 600

    assert_equal text.truncate(500), MessageSummarizer.call(text)
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat)
  end
end
# rubocop:enable Minitest/MultipleAssertions
