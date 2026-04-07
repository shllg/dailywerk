# frozen_string_literal: true

module Api
  module V1
    # WorkOS authentication endpoints for the SPA.
    #
    # Cookie-authenticated: login, me, refresh, config (skip Bearer auth).
    # Bearer-authenticated: logout, websocket_ticket.
    class AuthController < ApplicationController
      include ActionController::Cookies
      include CookieAuth

      skip_authentication! :login, :me, :refresh, :provider

      # GET /api/v1/auth/login — generates a PKCE authorization URL.
      #
      # @return [void]
      def login
        service = WorkosAuthService.new
        result = service.authorization_url(
          redirect_uri: auth_callback_url
        )

        set_oauth_state_cookie(result[:state])

        render json: { authorization_url: result[:authorization_url] }
      end

      # GET /api/v1/auth/me — restores the session from the auth cookie.
      # Returns a fresh access token, user, and workspace.
      #
      # @return [void]
      def me
        session = find_active_session
        return render_unauthorized unless session

        token_result = WorkosAuthService.new.refresh_access_token(user_session: session)
        user = session.user
        workspace = user.default_workspace

        render json: {
          access_token: token_result[:access_token],
          user: serialize_user(user),
          workspace: workspace ? serialize_workspace(workspace) : nil
        }
      rescue WorkosAuthService::RefreshLockUnavailableError
        render_refresh_retry_later
      rescue StandardError => e
        Rails.logger.warn "Auth me failed: #{e.message}"
        clear_session_cookie
        render_unauthorized
      end

      # POST /api/v1/auth/refresh — refreshes the access token.
      # Requires X-Requested-With header for CSRF protection.
      #
      # @return [void]
      def refresh
        unless request.headers["X-Requested-With"].present?
          return render json: { error: "Missing X-Requested-With header" }, status: :bad_request
        end

        session = find_active_session
        return render_unauthorized unless session

        token_result = WorkosAuthService.new.refresh_access_token(user_session: session)

        render json: { access_token: token_result[:access_token] }
      rescue WorkosAuthService::RefreshLockUnavailableError
        render_refresh_retry_later
      rescue StandardError => e
        Rails.logger.warn "Auth refresh failed: #{e.message}"
        clear_session_cookie
        render_unauthorized
      end

      # DELETE /api/v1/auth/logout — revokes the session and clears cookies.
      #
      # @return [void]
      def logout
        session = find_active_session
        logout_url = nil

        if session
          logout_url = WorkosAuthService.new.logout_url(user_session: session)
          session.revoke!
        end

        clear_session_cookie

        render json: { logout_url: }
      end

      # GET /api/v1/auth/provider — returns the authentication provider.
      #
      # @return [void]
      def provider
        render json: { provider: WorkOS::DailyWerk.enabled? ? "workos" : "dev" }
      end

      # POST /api/v1/auth/websocket_ticket — issues a one-time WebSocket ticket.
      #
      # @return [void]
      def websocket_ticket
        ticket = SecureRandom.urlsafe_base64(32)

        WebsocketTicketStore.issue(
          ticket:,
          user_id: current_user.id,
          workspace_id: current_workspace.id,
          expires_in: WorkOS::DailyWerk::WS_TICKET_TTL.seconds
        )

        render json: { ticket: }
      end

      private

      # Looks up an active UserSession from the auth cookie.
      #
      # @return [UserSession, nil]
      def find_active_session
        session_id = read_session_cookie
        return nil unless session_id

        UserSession.active.find_by(id: session_id)
      end

      # @param user [User]
      # @return [Hash]
      def serialize_user(user)
        { id: user.id, email: user.email, name: user.name }
      end

      # @param workspace [Workspace]
      # @return [Hash]
      def serialize_workspace(workspace)
        { id: workspace.id, name: workspace.name }
      end

      # @return [String]
      def auth_callback_url
        "#{request.protocol}#{request.host_with_port}/auth/workos/callback"
      end

      # @return [void]
      def render_refresh_retry_later
        response.set_header("Retry-After", "1")
        render json: { error: "Refresh already in progress" }, status: :too_many_requests
      end
    end
  end
end
