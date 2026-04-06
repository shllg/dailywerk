# frozen_string_literal: true

# Runs the compaction-aware chat flow for a session.
class AgentRuntime
  COMPACTION_THRESHOLD = 0.75
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
    enqueue_compaction_if_needed

    context = ContextBuilder.new(session: @session, agent: @agent).build
    runtime_session = @session.with_model(
      @agent.model_id,
      provider: @agent.resolved_provider || DEFAULT_PROVIDER
    )

    if context[:system_prompt].present?
      runtime_session = runtime_session.with_runtime_instructions(context[:system_prompt])
    end

    if @session.respond_to?(:workspace)
      tool_user = Current.user
      if tool_user.blank? && @session.workspace.respond_to?(:owner)
        tool_user = @session.workspace.owner
      end

      tools = @agent.tool_instances(user: tool_user, session: @session)
      runtime_session = runtime_session.with_tools(*tools) if tools.any?
    end
    runtime_session = runtime_session.with_temperature(@agent.temperature || 0.7)
    runtime_session = apply_thinking(runtime_session)
    runtime_session = apply_params(runtime_session)
    runtime_session.ask(user_message, &stream_block)
  end

  private

  # Applies provider-level thinking configuration when enabled on the agent.
  #
  # @param session [Object] the runtime session
  # @return [Object]
  def apply_thinking(session)
    config = @agent.thinking_config
    return session if config.empty?

    budget = config.dig(:thinking, :budget_tokens)
    session.with_thinking(budget: budget)
  end

  # Applies optional generation parameters from agent.params.
  #
  # @param session [Object] the runtime session
  # @return [Object]
  def apply_params(session)
    raw = @agent.params
    return session unless raw.is_a?(Hash)

    supported = raw.deep_stringify_keys.slice(
      "frequency_penalty", "max_tokens", "presence_penalty", "top_p", "stop"
    ).compact
    return session if supported.empty?

    session.with_params(**supported.symbolize_keys)
  end

  # Enqueues background compaction once the active context window crosses the threshold.
  # The threshold is intentionally lower than 100% so the current request can
  # still complete while the compaction job summarizes older history.
  #
  # @return [void]
  def enqueue_compaction_if_needed
    return unless @session.context_window_usage >= COMPACTION_THRESHOLD

    CompactionJob.perform_later(@session.id, workspace_id: @session.workspace_id)
  end
end
