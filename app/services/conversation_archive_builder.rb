# frozen_string_literal: true

# Produces durable archive summaries for completed sessions.
class ConversationArchiveBuilder
  DEFAULT_MODEL = "gpt-4o-mini"

  # @param session [Session]
  def initialize(session)
    @session = session
    @agent = session.agent
  end

  # @return [Hash]
  def build
    summary = archived_summary

    {
      summary:,
      key_facts: MemoryExtractionService.new(session: @session).extract(summary).map { |memory| memory[:content] }
    }
  end

  private

  # @return [String]
  def archived_summary
    return @session.summary if @session.summary.present?

    transcript = @session.messages
                         .where(role: %w[user assistant])
                         .order(:created_at)
                         .last(24)
                         .map { |message| "[#{message.role}] #{MessageSummarizer.call(message.content_for_context, model: archive_model)}" }
                         .join("\n")

    return "" if transcript.blank?

    RubyLLM.chat(model: archive_model)
            .with_temperature(0.1)
            .ask(
              <<~PROMPT
                Summarize this archived conversation so a future session can recover its important context.
                Preserve decisions, user preferences, standing instructions, names, deadlines, and key facts.
                Keep it concise and factual.

                Conversation:
                #{transcript}
              PROMPT
            ).content.to_s
  rescue StandardError => e
    Rails.logger.error("[ConversationArchive] Summary generation failed for session #{@session.id}: #{e.message}")
    @session.summary.to_s
  end

  # @return [String]
  def archive_model
    @agent.model_id.presence || DEFAULT_MODEL
  end
end
