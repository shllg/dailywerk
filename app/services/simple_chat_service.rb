# frozen_string_literal: true

# Runs a plain streaming conversation against the default OpenAI Responses model.
class SimpleChatService
  DEFAULT_PROVIDER = :openai_responses

  # @param session [Session]
  def initialize(session:)
    @session = session
    @agent = session.agent
  end

  # Streams a single assistant response for the given user message.
  #
  # @param user_message [String]
  # @yieldparam chunk [RubyLLM::Chunk]
  # @return [RubyLLM::Message]
  def call(user_message, &stream_block)
    @session
      .with_model(@agent.model_id, provider: @agent.resolved_provider || DEFAULT_PROVIDER)
      .with_instructions(@agent.resolved_instructions)
      .with_temperature(@agent.temperature || 0.7)
      .ask(user_message, &stream_block)
  end
end
