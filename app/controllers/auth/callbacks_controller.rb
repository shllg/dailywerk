# frozen_string_literal: true

module Auth
  # Handles the browser redirect from WorkOS after OAuth authentication.
  #
  # This controller lives outside the API namespace because it receives
  # a top-level browser redirect (not an XHR from the SPA). It validates
  # the PKCE state, exchanges the code, sets the auth session cookie, and
  # redirects to the SPA callback route.
  class CallbacksController < ActionController::API
    include ActionController::Cookies
    include CookieAuth

    # GET /auth/workos/callback?code=X&state=Y
    #
    # @return [void]
    def show
      oauth_state = read_oauth_state_cookie
      unless oauth_state
        return redirect_to_frontend("/login?error=missing_state")
      end

      unless ActiveSupport::SecurityUtils.secure_compare(oauth_state.to_s, params[:state].to_s)
        clear_oauth_state_cookie
        return redirect_to_frontend("/login?error=invalid_state")
      end

      session = WorkosAuthService.new.exchange_code(
        code: params[:code],
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )

      set_session_cookie(session.id)
      clear_oauth_state_cookie

      redirect_to_frontend("/auth/callback")
    rescue StandardError => e
      Rails.logger.error "Auth callback failed: #{e.message}"
      clear_oauth_state_cookie
      redirect_to_frontend("/login?error=auth_failed")
    end

    private

    # Redirects to the frontend origin. In dev the SPA runs on a different
    # port than Rails, so we need to use the frontend URL explicitly.
    #
    # @param path [String]
    # @return [void]
    def redirect_to_frontend(path)
      redirect_to "#{frontend_origin}#{path}", allow_other_host: true
    end

    # @return [String] the frontend origin URL
    def frontend_origin
      return "" unless Rails.env.local?

      vite_port = ENV.fetch("VITE_PORT", "5173")
      "http://localhost:#{vite_port}"
    end
  end
end
