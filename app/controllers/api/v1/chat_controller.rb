# frozen_string_literal: true

module Api
  module V1
    # Resolves the active chat session and enqueues streamed responses.
    class ChatController < ApplicationController
      # Loads the current session and visible message history.
      #
      # @return [void]
      def show
        agent = default_agent
        session = Session.resolve(agent:, gateway: "web")

        render json: {
          session_id: session.id,
          agent: AgentSerializer.summary(agent),
          session_summary: session.summary,
          context_window_usage: session.context_window_usage.round(2),
          messages: session.context_messages
                           .where(role: %w[user assistant system])
                           .order(:created_at)
                           .map { |message| MessageSerializer.summary(message) }
        }
      end

      # Enqueues a new streamed assistant response for the current session.
      #
      # @return [void]
      def create
        agent = default_agent
        session = Session.resolve(agent:, gateway: "web")
        content = message_params[:content].to_s.strip

        if content.blank?
          return render json: { error: "Content required" }, status: :unprocessable_entity
        end

        ChatStreamJob.perform_later(
          session.id,
          content,
          workspace_id: Current.workspace.id,
          user_id: Current.user.id
        )

        render json: { session_id: session.id }, status: :accepted
      end

      private

      # @return [Agent]
      def default_agent
        Current.workspace.agents.active.find_by!(is_default: true)
      end

      # @return [ActionController::Parameters]
      def message_params
        params.require(:message).permit(:content)
      end
    end
  end
end
