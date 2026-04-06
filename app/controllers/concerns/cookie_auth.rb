# frozen_string_literal: true

# Cookie helpers for WorkOS authentication controllers.
#
# Provides encrypted HttpOnly cookie management for the auth session
# (long-lived, carries session UUID) and the PKCE flow (short-lived,
# carries state + code_verifier during OAuth redirect).
#
# Uses MessageEncryptor for confidentiality + integrity (not just signing).
# Both cookies use SameSite=Lax to survive the OAuth redirect chain.
module CookieAuth
  extend ActiveSupport::Concern

  private

  SESSION_COOKIE = "_dw_auth"
  PKCE_COOKIE    = "_dw_pkce"

  # Sets the encrypted auth session cookie containing the UserSession UUID.
  #
  # @param session_id [String] the UserSession UUID
  # @return [void]
  def set_session_cookie(session_id)
    value = cookie_encryptor.encrypt_and_sign(session_id, purpose: :auth_session)
    set_cookie(SESSION_COOKIE, value, max_age: WorkOS::DailyWerk::SESSION_COOKIE_MAX_AGE, path: "/")
  end

  # Reads and decrypts the auth session cookie.
  #
  # @return [String, nil] the UserSession UUID, or nil if missing/invalid
  def read_session_cookie
    raw = cookies[SESSION_COOKIE]
    return nil unless raw.present?

    cookie_encryptor.decrypt_and_verify(raw, purpose: :auth_session)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  # Clears the auth session cookie.
  #
  # @return [void]
  def clear_session_cookie
    delete_cookie(SESSION_COOKIE, path: "/")
  end

  # Sets the encrypted PKCE cookie containing state and code_verifier.
  #
  # @param state [String] the OAuth state nonce
  # @param code_verifier [String] the PKCE code verifier
  # @return [void]
  def set_pkce_cookie(state:, code_verifier:)
    payload = { state:, code_verifier: }.to_json
    value = cookie_encryptor.encrypt_and_sign(payload, purpose: :pkce)
    set_cookie(PKCE_COOKIE, value, max_age: WorkOS::DailyWerk::PKCE_COOKIE_MAX_AGE, path: "/auth")
  end

  # Reads and decrypts the PKCE cookie.
  #
  # @return [Hash, nil] { "state" => ..., "code_verifier" => ... } or nil
  def read_pkce_cookie
    raw = cookies[PKCE_COOKIE]
    return nil unless raw.present?

    decrypted = cookie_encryptor.decrypt_and_verify(raw, purpose: :pkce)
    JSON.parse(decrypted)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
    nil
  end

  # Clears the PKCE cookie.
  #
  # @return [void]
  def clear_pkce_cookie
    delete_cookie(PKCE_COOKIE, path: "/auth")
  end

  # Sets a cookie with secure defaults.
  #
  # @param name [String]
  # @param value [String]
  # @param max_age [Integer]
  # @param path [String]
  # @return [void]
  def set_cookie(name, value, max_age:, path:)
    cookies[name] = {
      value:,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax,
      path:,
      expires: max_age.seconds.from_now
    }
  end

  # Deletes a cookie.
  #
  # @param name [String]
  # @param path [String]
  # @return [void]
  def delete_cookie(name, path:)
    cookies.delete(name, path:)
  end

  # Lazily builds a MessageEncryptor derived from the app secret.
  #
  # @return [ActiveSupport::MessageEncryptor]
  def cookie_encryptor
    @cookie_encryptor ||= begin
      secret = Rails.application.secret_key_base
      key = ActiveSupport::KeyGenerator.new(secret).generate_key("workos cookie auth", 32)
      ActiveSupport::MessageEncryptor.new(key)
    end
  end
end
