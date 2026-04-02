# frozen_string_literal: true

module ApplicationCable
  # Authenticates ActionCable connections with the API session token.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_workspace

    def connect
      payload = verified_payload
      self.current_user = find_verified_user(payload)
      self.current_workspace = find_verified_workspace(current_user, payload)
      Metrics::Registry.increment_action_cable_connections
      @metrics_connection_registered = true
    end

    def disconnect
      return unless @metrics_connection_registered

      Metrics::Registry.decrement_action_cable_connections
      @metrics_connection_registered = false
    end

    private

    # @return [Hash] the verified token payload
    def verified_payload
      token = request.params[:token]
      payload = Rails.application.message_verifier(:api_session).verified(token, purpose: :api_session)
      return payload if payload.is_a?(Hash)

      reject_unauthorized_connection
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      reject_unauthorized_connection
    end

    # @param payload [Hash]
    # @return [User]
    def find_verified_user(payload)
      user = User.active.find_by(id: payload["user_id"] || payload[:user_id])
      return user if user

      reject_unauthorized_connection
    end

    # @param user [User]
    # @param payload [Hash]
    # @return [Workspace]
    def find_verified_workspace(user, payload)
      workspace_id = payload["workspace_id"] || payload[:workspace_id]
      workspace =
        if workspace_id.present?
          user.workspaces.find_by(id: workspace_id)
        else
          user.default_workspace
        end

      workspace ||= user.default_workspace
      return workspace if workspace

      reject_unauthorized_connection
    end
  end
end
