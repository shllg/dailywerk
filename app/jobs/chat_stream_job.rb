# frozen_string_literal: true

# Streams assistant responses over ActionCable from a GoodJob worker.
class ChatStreamJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :llm

  discard_on ActiveRecord::RecordNotFound

  # Runs a single streamed LLM turn for the session.
  #
  # @param session_id [String]
  # @param user_message [String]
  # @param workspace_id [String]
  # @return [void]
  def perform(session_id, user_message, workspace_id:)
    session = Session.find(session_id)
    assistant_message = nil

    SimpleChatService.new(session:).call(user_message) do |chunk|
      next unless chunk.content.present?

      assistant_message ||= latest_assistant_message_for(session)
      ActionCable.server.broadcast(
        "session_#{session.id}",
        {
          type: "token",
          delta: chunk.content,
          message_id: assistant_message&.id
        }
      )
    end

    assistant_message = latest_assistant_message_for(session)
    ActionCable.server.broadcast(
      "session_#{session.id}",
      {
        type: "complete",
        content: assistant_message&.content,
        message_id: assistant_message&.id
      }
    )

    update_session_metadata(session, assistant_message)
  rescue StandardError => e
    ActionCable.server.broadcast(
      "session_#{session_id}",
      {
        type: "error",
        message: "Something went wrong. Please try again."
      }
    )
    Rails.logger.error("[ChatStream] Error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  end

  private

  # @param session [Session]
  # @return [Message, nil]
  def latest_assistant_message_for(session)
    session.messages.where(role: "assistant").order(created_at: :desc).first
  end

  # Updates session counters after the response is stored.
  #
  # @param session [Session]
  # @param message [Message, nil]
  # @return [void]
  def update_session_metadata(session, message)
    return unless message

    updates = {
      last_activity_at: Time.current,
      message_count: session.messages.count
    }

    if message.input_tokens.present? || message.output_tokens.present?
      updates[:total_tokens] = session.total_tokens.to_i + message.input_tokens.to_i + message.output_tokens.to_i
    end

    session.update!(updates)
  end
end
