# frozen_string_literal: true

require "test_helper"

class SimpleChatServiceTest < ActiveSupport::TestCase
  FakeSession = Struct.new(:agent, :calls, keyword_init: true) do
    def with_model(model_id, provider:)
      calls << [ :with_model, model_id, provider ]
      self
    end

    def with_instructions(instructions)
      calls << [ :with_instructions, instructions ]
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

  test "configures the session with the agent model and instructions" do
    agent = Agent.new(
      name: "DailyWerk",
      model_id: "gpt-5.4",
      instructions: "Be concise.",
      temperature: 0.2
    )
    session = FakeSession.new(agent:, calls: [])

    response = SimpleChatService.new(session:).call("Hello")

    assert_equal :response, response
    assert_equal(
      [
        [ :with_model, "gpt-5.4", SimpleChatService::DEFAULT_PROVIDER ],
        [ :with_instructions, "Be concise." ],
        [ :with_temperature, 0.2 ],
        [ :ask, "Hello" ]
      ],
      session.calls
    )
  end

  test "uses the agent provider when one is configured" do
    agent = Agent.new(
      name: "DailyWerk",
      model_id: "claude-3-7-sonnet",
      provider: "anthropic",
      instructions: "Be concise.",
      temperature: 0.2
    )
    session = FakeSession.new(agent:, calls: [])

    SimpleChatService.new(session:).call("Hello")

    assert_equal [ :with_model, "claude-3-7-sonnet", :anthropic ], session.calls.first
  end
end
