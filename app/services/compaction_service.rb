# frozen_string_literal: true

# Summarizes older session messages and marks them as compacted.
#
# This keeps a moving window of the newest `PRESERVE_RECENT` non-system
# messages verbatim. Everything older is summarized into `session.summary` and
# remains in the database for audit/debug purposes, but it no longer counts
# toward the active model context.
class CompactionService
  PRESERVE_RECENT = 10
  DEFAULT_SUMMARY_MODEL = "gpt-4o-mini"
  SUMMARY_REWRITE_THRESHOLD = 4_000
  PROTECTED_PATTERNS = [
    /```[\s\S]+?```/,
    /error|exception|fail/i,
    /decision:|decided:|agreed:/i
  ].freeze

  # @param session [Session]
  def initialize(session)
    @session = session
    @agent = session.agent
  end

  # Compacts old non-system messages into the session summary.
  # The preserved tail is the live conversation window; each compaction run
  # simply advances that window forward as the session grows.
  #
  # @return [Hash]
  def compact!
    active_messages = @session.messages
                              .for_context
                              .where.not(role: "system")
                              .to_a
    cutoff_index = active_messages.length - PRESERVE_RECENT
    return { compacted: false, reason: "too_few_messages" } if cutoff_index <= 0

    messages_to_compact = active_messages.first(cutoff_index)
    summary = generate_summary(
      messages_to_compact,
      extract_preserved_content(messages_to_compact)
    )
    return { compacted: false, reason: "summary_failed" } if summary.blank?

    ActiveRecord::Base.transaction do
      Message.where(id: messages_to_compact.map(&:id)).update_all(compacted: true)
      @session.update!(summary: combined_summary(summary))
    end

    {
      compacted: true,
      reason: "success",
      messages_compacted: messages_to_compact.length
    }
  rescue StandardError => e
    Rails.logger.error("[Compaction] Failed for session #{@session.id}: #{e.message}")
    { compacted: false, reason: "error: #{e.message}" }
  end

  private

  # Combines old and new summaries. When the combined size exceeds the
  # rewrite threshold, the LLM rewrites both into a single coherent summary
  # to prevent unbounded growth.
  #
  # @return [String]
  def combined_summary(new_summary)
    existing = @session.summary.presence
    return new_summary unless existing

    appended = "#{existing}\n\n---\n\n#{new_summary}"
    estimated_tokens = appended.length / 4

    if estimated_tokens > SUMMARY_REWRITE_THRESHOLD
      rewrite_summary(existing, new_summary)
    else
      appended
    end
  end

  # @param old_summary [String]
  # @param new_summary [String]
  # @return [String]
  def rewrite_summary(old_summary, new_summary)
    response = RubyLLM.chat(model: compaction_model)
                      .with_temperature(0.1)
                      .ask(<<~PROMPT)
                        Rewrite these two conversation summaries into a single coherent summary.
                        Preserve all facts, decisions, preferences, file paths, error messages,
                        and user-specific details. Discard redundancy and verbose transitions.

                        Earlier summary:
                        #{old_summary}

                        Newer summary:
                        #{new_summary}
                      PROMPT
    response.content.presence || "#{old_summary}\n\n---\n\n#{new_summary}"
  rescue StandardError => e
    Rails.logger.error("[Compaction] Summary rewrite failed: #{e.message}")
    "#{old_summary}\n\n---\n\n#{new_summary}"
  end

  # @return [String]
  def compaction_model
    normalized_agent_params["compaction_model"].presence || @agent.model_id || DEFAULT_SUMMARY_MODEL
  end

  # @param messages [Array<Message>]
  # @param preserved_facts [String]
  # @return [String, nil]
  def generate_summary(messages, preserved_facts)
    prior_context =
      if @session.summary.present?
        "PRIOR SUMMARY (incorporate and refine, do not discard):\n#{@session.summary}\n\n"
      else
        ""
      end

    response = RubyLLM.chat(model: compaction_model)
                      .with_temperature(0.1)
                      .ask(
                        <<~PROMPT
                          Summarize this conversation segment concisely. Preserve:
                          - Key decisions and rationale
                          - Specific facts, numbers, file paths, and error messages
                          - User preferences and instructions
                          - Tool call results that informed decisions

                          Discard greetings, acknowledgments, and verbose explanations.

                          #{prior_context}#{preserved_facts}
                          Conversation to summarize:
                          #{format_messages(messages)}
                        PROMPT
                      )

    response.content
  end

  # @param messages [Array<Message>]
  # @return [String]
  def format_messages(messages)
    model = compaction_model
    messages.map do |message|
      text = MessageSummarizer.call(message.content_for_context, model:)
      "[#{message.role}] #{text}"
    end.join("\n")
  end

  # @param messages [Array<Message>]
  # @return [String]
  def extract_preserved_content(messages)
    preserved_values = messages.each_with_object([]) do |message, values|
      PROTECTED_PATTERNS.each do |pattern|
        matches = message.content_for_context.to_s.scan(pattern)
        values.concat(Array(matches)) if matches.any?
      end
    end

    return "" if preserved_values.empty?

    "MUST PRESERVE:\n#{preserved_values.join("\n")}\n\n"
  end

  # @return [Hash]
  def normalized_agent_params
    @normalized_agent_params ||= @agent.params.is_a?(Hash) ? @agent.params.deep_stringify_keys : {}
  end
end
