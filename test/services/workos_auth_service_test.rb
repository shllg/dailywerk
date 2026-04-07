# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class WorkosAuthServiceTest < ActiveSupport::TestCase
  setup do
    @service = WorkosAuthService.new
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

  test "authorization_url returns URL with state nonce" do
    result = @service.authorization_url(redirect_uri: "http://localhost:3000/auth/callback")

    assert_predicate result[:authorization_url], :present?
    assert_predicate result[:state], :present?
  end

  test "exchange_code creates new user and session" do
    workos_user = build_workos_user(
      id: "user_workos_new_#{SecureRandom.hex(4)}",
      email: "new-#{SecureRandom.hex(4)}@dailywerk.com",
      first_name: "Test",
      last_name: "User",
      email_verified: true
    )

    stub_authenticate_with_code(workos_user:)

    session = @service.exchange_code(
      code: "test_code",

      ip_address: "127.0.0.1",
      user_agent: "TestAgent"
    )

    assert_instance_of UserSession, session
    assert_predicate session, :persisted?
    assert_equal "Test User", session.user.name
    assert_equal workos_user.email, session.user.email
    assert_predicate session.user.workspaces, :any?, "Expected default workspace to be created"
  ensure
    restore_authenticate_with_code
  end

  test "exchange_code links existing user by workos_id" do
    user = User.create!(
      email: "existing-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Existing",
      status: "active",
      workos_id: "user_workos_existing_#{SecureRandom.hex(4)}"
    )
    Workspace.create!(name: "Personal", owner: user).tap do |ws|
      WorkspaceMembership.create!(workspace: ws, user:, role: "owner")
    end

    workos_user = build_workos_user(
      id: user.workos_id,
      email: user.email,
      first_name: "Updated",
      last_name: "Name",
      email_verified: true
    )

    stub_authenticate_with_code(workos_user:)

    session = @service.exchange_code(code: "test_code")

    assert_equal user.id, session.user.id
    assert_equal "Updated Name", session.user.reload.name
  ensure
    restore_authenticate_with_code
  end

  test "exchange_code links existing user by verified email" do
    user = User.create!(
      email: "link-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Linkable",
      status: "active"
    )
    Workspace.create!(name: "Personal", owner: user).tap do |ws|
      WorkspaceMembership.create!(workspace: ws, user:, role: "owner")
    end

    new_workos_id = "user_workos_link_#{SecureRandom.hex(4)}"
    workos_user = build_workos_user(
      id: new_workos_id,
      email: user.email,
      first_name: "Linkable",
      last_name: "",
      email_verified: true
    )

    stub_authenticate_with_code(workos_user:)

    session = @service.exchange_code(code: "test_code")

    assert_equal user.id, session.user.id
    assert_equal new_workos_id, session.user.reload.workos_id
  ensure
    restore_authenticate_with_code
  end

  test "exchange_code rejects linking by unverified email" do
    User.create!(
      email: "noverify-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "NoVerify",
      status: "active"
    )

    workos_user = build_workos_user(
      id: "user_workos_noverify_#{SecureRandom.hex(4)}",
      email: User.last.email,
      first_name: "NoVerify",
      last_name: "",
      email_verified: false
    )

    stub_authenticate_with_code(workos_user:)

    error = assert_raises(RuntimeError) do
      @service.exchange_code(code: "test_code")
    end
    assert_match(/Cannot link unverified email/, error.message)
  ensure
    restore_authenticate_with_code
  end

  test "refresh_access_token raises a retryable error without clearing another request lock" do
    user, = create_user_with_workspace
    session = UserSession.create!(
      user:,
      refresh_token: "wos_rt_test_#{SecureRandom.hex(8)}",
      expires_at: 30.days.from_now
    )
    lock_key = "refresh_lock:session_#{session.id}"

    with_cache_store(ActiveSupport::Cache::MemoryStore.new) do
      Rails.cache.write(lock_key, "1", unless_exist: true, expires_in: 5.seconds)

      error = assert_raises(WorkosAuthService::RefreshLockUnavailableError) do
        @service.refresh_access_token(user_session: session)
      end

      assert_match(/lock contention/, error.message)
      assert_equal "1", Rails.cache.read(lock_key)
    end
  end

  private

  # Builds a fake WorkOS::User-like struct for testing.
  def build_workos_user(id:, email:, first_name:, last_name:, email_verified:)
    Struct.new(:id, :email, :first_name, :last_name, :email_verified, :profile_picture_url,
               keyword_init: true).new(
      id:, email:, first_name:, last_name:, email_verified:, profile_picture_url: nil
    )
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

  def with_cache_store(store)
    original_cache = Rails.cache
    Rails.cache = store
    yield
  ensure
    Rails.cache = original_cache
  end
end
# rubocop:enable Minitest/MultipleAssertions
