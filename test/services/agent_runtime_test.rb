# frozen_string_literal: true

require "test_helper"

class AgentRuntimeTest < ActiveSupport::TestCase
  FakeSession = Struct.new(
    :agent,
    :calls,
    :context_window_usage,
    :workspace_id,
    :id,
    keyword_init: true
  ) do
    def with_model(model_id, provider:)
      calls << [ :with_model, model_id, provider ]
      self
    end

    def with_runtime_instructions(instructions)
      calls << [ :with_runtime_instructions, instructions ]
      self
    end

    def with_temperature(temperature)
      calls << [ :with_temperature, temperature ]
      self
    end

    def ask(message)
      calls << [ :ask, message ]
      yield OpenStruct.new(content: "chunk") if block_given?
      :response
    end
  end

  test "configures the session with runtime instructions" do
    agent = Agent.new(name: "DailyWerk", model_id: "gpt-5.4", instructions: "Be concise.", temperature: 0.2)
    session = FakeSession.new(
      agent:,
      calls: [],
      context_window_usage: 0.2,
      workspace_id: SecureRandom.uuid,
      id: SecureRandom.uuid
    )
    fake_builder = Struct.new(:payload) do
      def build
        payload
      end
    end.new({ system_prompt: "Prompt", active_message_count: 0, estimated_tokens: 0 })
    original_builder = ContextBuilder.method(:new)

    ContextBuilder.define_singleton_method(:new) do |session:, agent:|
      fake_builder
    end

    response = AgentRuntime.new(session:).call("Hello")

    assert_equal :response, response
    assert_equal(
      [
        [ :with_model, "gpt-5.4", AgentRuntime::DEFAULT_PROVIDER ],
        [ :with_runtime_instructions, "Prompt" ],
        [ :with_temperature, 0.2 ],
        [ :ask, "Hello" ]
      ],
      session.calls
    )
  ensure
    ContextBuilder.define_singleton_method(:new, original_builder)
  end

  test "enqueues compaction when the context threshold is crossed" do
    agent = Agent.new(name: "DailyWerk", model_id: "gpt-5.4")
    session = FakeSession.new(
      agent:,
      calls: [],
      context_window_usage: 0.8,
      workspace_id: SecureRandom.uuid,
      id: SecureRandom.uuid
    )
    fake_builder = Struct.new(:payload) do
      def build
        payload
      end
    end.new({ system_prompt: "", active_message_count: 0, estimated_tokens: 0 })
    original_builder = ContextBuilder.method(:new)
    original_enqueue = CompactionJob.method(:perform_later)
    enqueued = []

    ContextBuilder.define_singleton_method(:new) do |session:, agent:|
      fake_builder
    end
    CompactionJob.define_singleton_method(:perform_later) do |session_id, workspace_id:|
      enqueued << [ session_id, workspace_id ]
    end

    AgentRuntime.new(session:).call("Hello")

    assert_equal [ [ session.id, session.workspace_id ] ], enqueued
  ensure
    ContextBuilder.define_singleton_method(:new, original_builder)
    CompactionJob.define_singleton_method(:perform_later, original_enqueue)
  end
end
