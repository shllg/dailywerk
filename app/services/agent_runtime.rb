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
    runtime_session.ask(user_message, &stream_block)
  end

  private

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
