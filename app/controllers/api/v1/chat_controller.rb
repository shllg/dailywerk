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
          agent: {
            id: agent.id,
            slug: agent.slug,
            name: agent.name
          },
          messages: session.messages
                           .where(role: %w[user assistant system])
                           .order(:created_at)
                           .map { |message| message_json(message) }
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

        ChatStreamJob.perform_later(session.id, content, workspace_id: Current.workspace.id)

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

      # @param message [Message]
      # @return [Hash]
      def message_json(message)
        {
          id: message.id,
          role: message.role,
          content: message.content.to_s,
          timestamp: message.created_at.iso8601
        }
      end
    end
  end
end
