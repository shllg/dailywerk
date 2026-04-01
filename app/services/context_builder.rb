# frozen_string_literal: true

# Assembles the runtime prompt for a session.
#
# The prompt has three layers of memory:
# 1. The agent's static instructions from PromptBuilder.
# 2. The session summary, which represents older compacted history.
# 3. A short sliding bridge window from the most recently archived session.
#
# The bridge is only used for a brand-new rotated session. Once the new session
# has its own messages, the bridge disappears and the session stands on its own.
class ContextBuilder
  BRIDGE_MESSAGE_LIMIT = 10
  PREVIOUS_CONTEXT_TITLE = "## Previous Context"
  RECENT_MESSAGES_TITLE = "## Recent Messages (from previous session)"

  # @param session [Session]
  # @param agent [Agent]
  def initialize(session:, agent: session.agent)
    @session = session
    @agent = agent
  end

  # Builds the runtime prompt and metadata used by AgentRuntime.
  #
  # @return [Hash]
  def build
    prompt_parts = [ PromptBuilder.new(@agent).build ]

    if @session.summary.present?
      prompt_parts << "#{PREVIOUS_CONTEXT_TITLE}\n\n#{@session.summary}"
    end

    bridge_messages = bridge_messages_context
    prompt_parts << bridge_messages if bridge_messages.present?

    {
      system_prompt: prompt_parts.compact_blank.join("\n\n"),
      active_message_count: @session.context_messages.count,
      estimated_tokens: @session.estimated_context_tokens
    }
  end

  private

  # Returns summarized bridge messages from the most recently archived session.
  # This behaves like a sliding window: we only take the newest
  # `BRIDGE_MESSAGE_LIMIT` user/assistant messages because older context should
  # already be represented by the inherited summary.
  #
  # @return [String, nil]
  def bridge_messages_context
    return nil if @session.context_messages.exists?

    previous_session = find_previous_session
    return nil unless previous_session

    messages = previous_session.messages
                               .active
                               .where(role: %w[user assistant])
                               .order(created_at: :desc)
                               .limit(BRIDGE_MESSAGE_LIMIT)
                               .reverse
    return nil if messages.empty?

    summarized_messages = messages.map do |message|
      text = MessageSummarizer.call(
        message.content_for_context,
        model: compaction_model
      )
      "[#{message.role}] #{text}"
    end

    "#{RECENT_MESSAGES_TITLE}\n\n#{summarized_messages.join("\n")}"
  end

  # Finds the archived session immediately preceding the current one.
  #
  # @return [Session, nil]
  def find_previous_session
    Current.without_workspace_scoping do
      Session.where(
        agent: @agent,
        workspace_id: @session.workspace_id,
        status: "archived"
      ).where.not(id: @session.id)
       .order(ended_at: :desc)
       .first
    end
  end

  # @return [String]
  def compaction_model
    normalized_agent_params["compaction_model"].presence || @agent.model_id || "gpt-4o-mini"
  end

  # @return [Hash]
  def normalized_agent_params
    @normalized_agent_params ||= @agent.params.is_a?(Hash) ? @agent.params.deep_stringify_keys : {}
  end
end
