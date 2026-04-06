# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class Api::V1::AuthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user, @workspace = create_user_with_workspace
    @original_client_id = ENV["WORKOS_CLIENT_ID"]
    ENV["WORKOS_CLIENT_ID"] = "client_test_123"
  end

  teardown do
    if @original_client_id
      ENV["WORKOS_CLIENT_ID"] = @original_client_id
    else
      ENV.delete("WORKOS_CLIENT_ID")
    end
  end

  # -- provider --

  test "provider returns provider type" do
    get "/api/v1/auth/provider"

    assert_response :success
    body = JSON.parse(response.body)

    assert_includes %w[workos dev], body["provider"]
  end

  # -- login --

  test "login returns authorization URL and sets PKCE cookie" do
    get "/api/v1/auth/login"

    assert_response :success
    body = JSON.parse(response.body)

    assert_predicate body["authorization_url"], :present?
    assert_includes body["authorization_url"], "code_challenge="
    assert_includes response.headers["Set-Cookie"], "_dw_pkce="
  end

  # -- me --

  test "me with valid session cookie returns access token and user" do
    session = create_user_session(@user)
    stub_refresh_token
    set_auth_session_cookie(session)

    get "/api/v1/auth/me"

    assert_response :success
    body = JSON.parse(response.body)

    assert_predicate body["access_token"], :present?
    assert_equal @user.email, body["user"]["email"]
    assert_equal @workspace.name, body["workspace"]["name"]
  ensure
    restore_refresh_token
  end

  test "me without session cookie returns 401" do
    get "/api/v1/auth/me"

    assert_response :unauthorized
  end

  # -- refresh --

  test "refresh with valid session and X-Requested-With returns new token" do
    session = create_user_session(@user)
    stub_refresh_token
    set_auth_session_cookie(session)

    post "/api/v1/auth/refresh", headers: { "X-Requested-With" => "XMLHttpRequest" }

    assert_response :success
    body = JSON.parse(response.body)

    assert_predicate body["access_token"], :present?
  ensure
    restore_refresh_token
  end

  test "refresh without X-Requested-With returns 400" do
    session = create_user_session(@user)
    set_auth_session_cookie(session)

    post "/api/v1/auth/refresh"

    assert_response :bad_request
  end

  # -- logout --

  test "logout revokes session and clears cookie" do
    session = create_user_session(@user)
    set_auth_session_cookie(session)

    delete "/api/v1/auth/logout",
           headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    assert_predicate session.reload, :revoked?
  end

  # -- websocket_ticket --

  test "websocket_ticket returns a ticket string" do
    post "/api/v1/auth/websocket_ticket",
         headers: api_auth_headers(user: @user, workspace: @workspace)

    assert_response :success
    body = JSON.parse(response.body)

    assert_predicate body["ticket"], :present?
    assert_operator body["ticket"].length, :>, 20, "Expected ticket to be a sufficiently long random string"
  end

  test "websocket_ticket without auth returns 401" do
    post "/api/v1/auth/websocket_ticket"

    assert_response :unauthorized
  end

  private

  def create_user_session(user)
    UserSession.create!(
      user:,
      refresh_token: "wos_rt_test_#{SecureRandom.hex(8)}",
      expires_at: 30.days.from_now
    )
  end

  def set_auth_session_cookie(user_session)
    encryptor = build_cookie_encryptor
    value = encryptor.encrypt_and_sign(user_session.id, purpose: :auth_session)
    cookies["_dw_auth"] = value
  end

  def build_cookie_encryptor
    secret = Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(secret).generate_key("workos cookie auth", 32)
    ActiveSupport::MessageEncryptor.new(key)
  end

  def stub_refresh_token
    response = Struct.new(:access_token, :refresh_token, keyword_init: true).new(
      access_token: "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.test",
      refresh_token: "wos_rt_refreshed_#{SecureRandom.hex(8)}"
    )

    @original_refresh = WorkOS::UserManagement.method(:authenticate_with_refresh_token)
    WorkOS::UserManagement.define_singleton_method(:authenticate_with_refresh_token) do |**_kwargs|
      response
    end
  end

  def restore_refresh_token
    return unless @original_refresh

    WorkOS::UserManagement.define_singleton_method(:authenticate_with_refresh_token, @original_refresh)
    @original_refresh = nil
  end
end
# rubocop:enable Minitest/MultipleAssertions
