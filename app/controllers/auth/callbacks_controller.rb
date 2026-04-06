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

    # GET /auth/callback?code=X&state=Y
    #
    # @return [void]
    def show
      pkce = read_pkce_cookie
      unless pkce
        return redirect_to_login("missing_pkce")
      end

      unless ActiveSupport::SecurityUtils.secure_compare(pkce["state"].to_s, params[:state].to_s)
        clear_pkce_cookie
        return redirect_to_login("invalid_state")
      end

      session = WorkosAuthService.new.exchange_code(
        code: params[:code],
        code_verifier: pkce["code_verifier"],
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )

      set_session_cookie(session.id)
      clear_pkce_cookie

      redirect_to "/auth/callback", allow_other_host: false
    rescue StandardError => e
      Rails.logger.error "Auth callback failed: #{e.message}"
      clear_pkce_cookie
      redirect_to_login("auth_failed")
    end

    private

    # @param reason [String]
    # @return [void]
    def redirect_to_login(reason)
      redirect_to "/login?error=#{reason}", allow_other_host: false
    end
  end
end
