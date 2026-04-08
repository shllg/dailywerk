# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class Auth::CallbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_client_id = Rails.configuration.x.workos.client_id
    Rails.configuration.x.workos.client_id = "client_test_123"
  end

  teardown do
    Rails.configuration.x.workos.client_id = @original_client_id
    restore_authenticate_with_code
  end

  test "valid callback sets session cookie and redirects to SPA" do
    workos_user = build_workos_user
    stub_authenticate_with_code(workos_user:)

    state = "test_state_123"
    cookies["_dw_oauth_state"] = build_state_cookie(state)

    get "/auth/workos/callback", params: { code: "auth_code", state: }

    assert_response :redirect
    assert_match %r{/auth/callback\z}, response.location
  end

  test "missing state cookie redirects to login with error" do
    get "/auth/workos/callback", params: { code: "auth_code", state: "any" }

    assert_response :redirect
    assert_match(/login\?error=missing_state/, response.location)
  end

  test "invalid state redirects to login with error" do
    cookies["_dw_oauth_state"] = build_state_cookie("correct_state")

    get "/auth/workos/callback", params: { code: "auth_code", state: "wrong_state" }

    assert_response :redirect
    assert_match(/login\?error=invalid_state/, response.location)
  end

  private

  def build_workos_user
    Struct.new(:id, :email, :first_name, :last_name, :email_verified, :profile_picture_url,
               keyword_init: true).new(
      id: "user_workos_cb_#{SecureRandom.hex(4)}",
      email: "callback-#{SecureRandom.hex(4)}@dailywerk.com",
      first_name: "Test",
      last_name: "Callback",
      email_verified: true,
      profile_picture_url: nil
    )
  end

  def build_state_cookie(state)
    encryptor = build_cookie_encryptor
    encryptor.encrypt_and_sign(state, purpose: :oauth_state)
  end

  def build_cookie_encryptor
    secret = Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(secret).generate_key("workos cookie auth", 32)
    ActiveSupport::MessageEncryptor.new(key)
  end

  def stub_authenticate_with_code(workos_user:)
    response = Struct.new(:user, :access_token, :refresh_token, :organization_id,
                          keyword_init: true).new(
      user: workos_user,
      access_token: "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.fake",
      refresh_token: "wos_rt_test_#{SecureRandom.hex(8)}",
      organization_id: nil
    )

    @original_auth = WorkOS::UserManagement.method(:authenticate_with_code)
    WorkOS::UserManagement.define_singleton_method(:authenticate_with_code) do |**_kwargs|
      response
    end
  end

  def restore_authenticate_with_code
    return unless @original_auth

    WorkOS::UserManagement.define_singleton_method(:authenticate_with_code, @original_auth)
    @original_auth = nil
  end
end
# rubocop:enable Minitest/MultipleAssertions
