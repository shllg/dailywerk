# frozen_string_literal: true

# Assembles the runtime prompt for a session.
#
# The prompt has three layers of memory:
# 1. The agent's static instructions from PromptBuilder.
# 2. The session summary, which represents older compacted history.
# 3. Structured long-term memory and archive snippets from prior sessions.
# 4. A short sliding bridge window from the most recently archived session.
#
# The bridge is only used for a brand-new rotated session. Once the new session
# has its own messages, the bridge disappears and the session stands on its own.
class ContextBuilder
  BRIDGE_MESSAGE_LIMIT = 10
  USER_PROFILE_TITLE = "## About This User"
  KNOWLEDGE_CONTRACT_TITLE = "## Knowledge Contract"
  AVAILABLE_VAULTS_TITLE = "## Available Vaults"
  LONG_TERM_MEMORY_TITLE = "## Structured Memory"
  PREVIOUS_CONTEXT_TITLE = "## Previous Context"
  RELEVANT_ARCHIVES_TITLE = "## Relevant Archived Context"
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
    prompt_parts << user_profile_section
    prompt_parts << knowledge_contract_section
    prompt_parts << available_vaults_section

    if @session.summary.present?
      prompt_parts << "#{PREVIOUS_CONTEXT_TITLE}\n\n#{@session.summary}"
    end

    prompt_parts << long_term_memory_section

    bridge_messages = bridge_messages_context
    prompt_parts << bridge_messages if bridge_messages.present?

    {
      system_prompt: prompt_parts.compact_blank.join("\n\n"),
      active_message_count: @session.context_messages.count,
      estimated_tokens: @session.estimated_context_tokens
    }
  end

  private

  # @return [String, nil]
  def user_profile_section
    return nil unless Current.user && Current.workspace

    profile = UserProfile.find_by(user: Current.user, workspace: Current.workspace)
    return nil if profile&.synthesized_profile.blank?

    "#{USER_PROFILE_TITLE}\n\n#{profile.synthesized_profile}"
  end

  # @return [String]
  def knowledge_contract_section
    vault_line = if active_vaults.any?
      "- Vault: user-authored documents and files that hold longer-form notes, artifacts, and reference material."
    else
      "- Vault: no vault is configured yet."
    end

    <<~TEXT.strip
      #{KNOWLEDGE_CONTRACT_TITLE}

      This workspace uses the following persistent knowledge systems:
      - Structured memory: curated long-term facts, preferences, rules, and ongoing context stored in the database.
      #{vault_line}

      Treat both as valid context. Use structured memory for durable recall and the vault for richer source material.
      If the user corrects old information, prefer the newer user statement and update memory accordingly.
      Use shared memory for user-wide facts and preferences. Use private memory for agent-specific specialist context.
    TEXT
  end

  # @return [String, nil]
  def available_vaults_section
    return nil if active_vaults.empty?

    preamble = if active_vaults.one?
      "This workspace has one vault. Pass `vault_slug: null` to use it by default."
    else
      "This workspace has #{active_vaults.size} vaults. You must pass `vault_slug` to target the correct vault."
    end

    lines = active_vaults.map do |vault|
      "- **#{vault.name}** (slug: `#{vault.slug}`, type: #{vault.vault_type}, files: #{vault.file_count})"
    end

    [
      AVAILABLE_VAULTS_TITLE,
      preamble,
      lines.join("\n")
    ].join("\n\n")
  end

  # @return [String, nil]
  def long_term_memory_section
    payload = MemoryRetrievalService.new(session: @session).build_context
    memories = payload[:memories]
    archives = payload[:archives]

    parts = []
    if memories.any?
      memory_lines = memories.map do |entry|
        scope = entry.shared? ? "shared" : "private:#{entry.agent&.slug || 'agent'}"
        "[#{scope}] [#{entry.category}] #{entry.content}"
      end
      parts << "#{LONG_TERM_MEMORY_TITLE}\n\n#{memory_lines.join("\n")}"
    end

    if archives.any?
      archive_lines = archives.map do |archive|
        "- #{archive.summary}"
      end
      parts << "#{RELEVANT_ARCHIVES_TITLE}\n\n#{archive_lines.join("\n")}"
    end

    parts.compact_blank.join("\n\n").presence
  end

  # Returns a deterministic session recap plus summarized bridge messages from
  # the most recently archived session. The recap always fires on a new session
  # so the agent acknowledges the previous conversation regardless of semantic
  # relevance.
  #
  # @return [String, nil]
  def bridge_messages_context
    return nil if @session.context_messages.exists?

    previous_session = find_previous_session
    return nil unless previous_session

    parts = []
    parts << deterministic_recap(previous_session)

    messages = previous_session.messages
                               .active
                               .where(role: %w[user assistant])
                               .order(created_at: :desc)
                               .limit(BRIDGE_MESSAGE_LIMIT)
                               .reverse

    if messages.any?
      summarized_texts = MessageSummarizer.batch_call(
        messages.map(&:content_for_context),
        model: compaction_model
      )
      summarized_messages = messages.zip(summarized_texts).map do |message, text|
        "[#{message.role}] #{text}"
      end
      parts << "#{RECENT_MESSAGES_TITLE}\n\n#{summarized_messages.join("\n")}"
    end

    parts.compact_blank.join("\n\n").presence
  end

  # Produces a 1-2 sentence recap from the previous session's archive or summary.
  #
  # @param previous_session [Session]
  # @return [String, nil]
  def deterministic_recap(previous_session)
    archive = previous_session.conversation_archive
    text = archive&.summary.presence || previous_session.summary.presence
    return nil if text.blank?

    first_sentences = text.split(/(?<=[.!?])\s+/).first(2).join(" ")
    date = (previous_session.ended_at || previous_session.last_activity_at)&.strftime("%B %d")
    date_part = date ? " (on #{date})" : ""
    "Your last conversation with this user#{date_part} was about: #{first_sentences}"
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

  # @return [Array<Vault>]
  def active_vaults
    @active_vaults ||= @session.workspace&.vaults&.active&.order(:name)&.to_a || []
  end
end
