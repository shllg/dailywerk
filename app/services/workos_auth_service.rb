# frozen_string_literal: true

require "securerandom"

# Orchestrates the WorkOS OAuth flow: authorization URL generation, code
# exchange, user find-or-create, token refresh, and logout URL retrieval.
#
# Note: PKCE is not used because the WorkOS Ruby SDK (v5) does not expose
# code_challenge/code_verifier parameters. This is a server-side confidential
# client — the authorization code never touches the browser, so PKCE is not
# required. The `state` parameter provides OAuth CSRF protection.
class WorkosAuthService
  # Generates an authorization URL for WorkOS with a state nonce.
  #
  # @param redirect_uri [String] the callback URL
  # @return [Hash] { authorization_url:, state: }
  def authorization_url(redirect_uri:)
    state = SecureRandom.urlsafe_base64(24)

    url = WorkOS::UserManagement.authorization_url(
      redirect_uri:,
      client_id: client_id,
      state:,
      provider: "authkit"
    )

    { authorization_url: url, state: }
  end

  # Exchanges an authorization code for tokens and finds or creates the user.
  #
  # @param code [String] the authorization code from WorkOS
  # @param ip_address [String, nil]
  # @param user_agent [String, nil]
  # @return [UserSession]
  def exchange_code(code:, ip_address: nil, user_agent: nil)
    response = WorkOS::UserManagement.authenticate_with_code(
      code:,
      client_id: client_id,
      ip_address:,
      user_agent:
    )

    user = find_or_create_user(response.user)
    ensure_default_workspace(user)

    UserSession.create!(
      user:,
      refresh_token: response.refresh_token,
      workos_session_id: extract_session_id(response),
      expires_at: 30.days.from_now,
      ip_address:,
      user_agent: user_agent&.truncate(500)
    )
  end

  # Refreshes the access token using the stored refresh token.
  # Uses a cache lock to prevent concurrent refresh races.
  #
  # @param user_session [UserSession]
  # @return [Hash] { access_token: }
  def refresh_access_token(user_session:)
    lock_key = "refresh_lock:session_#{user_session.id}"

    # Acquire a Valkey lock to prevent concurrent refreshes
    acquired = Rails.cache.write(lock_key, "1", unless_exist: true, expires_in: 5.seconds)
    unless acquired
      # Another request is refreshing — wait briefly and retry once
      sleep 0.5
      acquired = Rails.cache.write(lock_key, "1", unless_exist: true, expires_in: 5.seconds)
      raise "Refresh token lock contention" unless acquired
    end

    response = WorkOS::UserManagement.authenticate_with_refresh_token(
      refresh_token: user_session.refresh_token,
      client_id: client_id
    )

    # Update stored refresh token if rotated
    if response.refresh_token.present? && response.refresh_token != user_session.refresh_token
      user_session.update!(refresh_token: response.refresh_token)
    end

    { access_token: response.access_token }
  ensure
    Rails.cache.delete(lock_key) if lock_key
  end

  # Returns the WorkOS logout URL for ending the SSO session.
  #
  # @param user_session [UserSession]
  # @return [String, nil]
  def logout_url(user_session:)
    return nil unless user_session.workos_session_id.present?

    WorkOS::UserManagement.get_logout_url(session_id: user_session.workos_session_id)
  rescue StandardError => e
    Rails.logger.warn "WorkosAuthService: failed to get logout URL: #{e.message}"
    nil
  end

  private

  # @return [String]
  def client_id
    WorkOS::DailyWerk.client_id
  end

  # Finds an existing user by workos_id or verified email, or creates a new one.
  #
  # @param workos_user [WorkOS::User]
  # @return [User]
  def find_or_create_user(workos_user)
    # 1. Find by workos_id — update email/name if changed
    user = User.find_by(workos_id: workos_user.id)
    return sync_user_attributes(user, workos_user) if user

    # 2. Find by email — link workos_id only if email is verified
    user = User.find_by(email: workos_user.email)
    if user
      unless workos_user.email_verified
        raise "Cannot link unverified email #{workos_user.email} to existing account"
      end

      # Use update_column to bypass attr_readonly — this is a one-time link
      user.update_column(:workos_id, workos_user.id)
      return sync_user_attributes(user, workos_user)
    end

    # 3. Create new user
    User.create!(
      workos_id: workos_user.id,
      email: workos_user.email,
      name: build_name(workos_user),
      status: "active"
    )
  end

  # Syncs name and email from WorkOS if changed.
  #
  # @param user [User]
  # @param workos_user [WorkOS::User]
  # @return [User]
  def sync_user_attributes(user, workos_user)
    attrs = {}
    new_name = build_name(workos_user)
    attrs[:name] = new_name if new_name.present? && new_name != user.name
    attrs[:email] = workos_user.email if workos_user.email != user.email
    user.update!(attrs) if attrs.any?
    user
  end

  # Constructs a display name from WorkOS first/last name fields.
  #
  # @param workos_user [WorkOS::User]
  # @return [String]
  def build_name(workos_user)
    [ workos_user.first_name, workos_user.last_name ].compact_blank.join(" ").presence ||
      workos_user.email.split("@").first
  end

  # Creates a default workspace for a newly created user.
  #
  # @param user [User]
  # @return [void]
  def ensure_default_workspace(user)
    return if user.workspaces.any?

    workspace = Workspace.create!(name: "Personal", owner: user)
    WorkspaceMembership.create!(workspace:, user:, role: "owner")
  end

  # Extracts session ID from the auth response if available.
  #
  # @param response [WorkOS::AuthenticationResponse]
  # @return [String, nil]
  def extract_session_id(response)
    # WorkOS v5 includes session metadata via sealed_session or access_token claims
    # The session_id may be in the access token payload
    return nil unless response.access_token.present?

    payload = JSON.parse(Base64.urlsafe_decode64(response.access_token.split(".")[1]))
    payload["sid"]
  rescue StandardError
    nil
  end
end
