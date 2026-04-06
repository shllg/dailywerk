# frozen_string_literal: true

module ApplicationCable
  # Authenticates ActionCable connections using one-time Valkey tickets.
  #
  # The SPA obtains a ticket via POST /api/v1/auth/websocket_ticket,
  # then connects with ?ticket=<value>. The ticket is consumed atomically
  # on first use (15-second TTL, deleted after read).
  #
  # Falls back to MessageVerifier token auth in local development for
  # backward compatibility during the WorkOS transition.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_workspace

    def connect
      if request.params[:ticket].present?
        authenticate_with_ticket!
      elsif request.params[:token].present? && Rails.env.local?
        authenticate_with_legacy_token!
      else
        reject_unauthorized_connection
      end

      Metrics::Registry.increment_action_cable_connections
      @metrics_connection_registered = true
    end

    def disconnect
      return unless @metrics_connection_registered

      Metrics::Registry.decrement_action_cable_connections
      @metrics_connection_registered = false
    end

    private

    # Authenticates via a one-time Valkey ticket.
    #
    # @return [void]
    def authenticate_with_ticket!
      ticket = request.params[:ticket]
      data = Rails.cache.read("ws_ticket:#{ticket}")
      reject_unauthorized_connection unless data

      # Delete ticket after read (one-time use)
      Rails.cache.delete("ws_ticket:#{ticket}")

      parsed = JSON.parse(data)
      self.current_user = User.find(parsed["user_id"])
      self.current_workspace = Workspace.find(parsed["workspace_id"])
    rescue ActiveRecord::RecordNotFound, JSON::ParserError
      reject_unauthorized_connection
    end

    # Legacy: authenticates via MessageVerifier token (dev/test only).
    #
    # @return [void]
    def authenticate_with_legacy_token!
      token = request.params[:token]
      payload = Rails.application.message_verifier(:api_session).verified(token, purpose: :api_session)
      reject_unauthorized_connection unless payload.is_a?(Hash)

      self.current_user = User.active.find_by!(id: payload["user_id"] || payload[:user_id])
      self.current_workspace = resolve_workspace(current_user, payload)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      reject_unauthorized_connection
    end

    # @param user [User]
    # @param payload [Hash]
    # @return [Workspace]
    def resolve_workspace(user, payload)
      workspace_id = payload["workspace_id"] || payload[:workspace_id]
      workspace = workspace_id.present? ? user.workspaces.find_by(id: workspace_id) : nil
      workspace || user.default_workspace || reject_unauthorized_connection
    end
  end
end
