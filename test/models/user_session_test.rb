# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class UserSessionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "session-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Tester",
      status: "active"
    )
  end

  test "encrypts and decrypts refresh_token round-trip" do
    session = UserSession.create!(
      user: @user,
      refresh_token: "wos_rt_secret_value_12345",
      expires_at: 30.days.from_now
    )

    session.reload

    assert_equal "wos_rt_secret_value_12345", session.refresh_token
  end

  test "active scope returns non-revoked, non-expired sessions" do
    active = UserSession.create!(user: @user, expires_at: 1.day.from_now)
    expired = UserSession.create!(user: @user, expires_at: 1.hour.ago)
    revoked = UserSession.create!(user: @user, expires_at: 1.day.from_now, revoked_at: Time.current)

    active_ids = @user.user_sessions.active.pluck(:id)

    assert_includes active_ids, active.id
    assert_not_includes active_ids, expired.id
    assert_not_includes active_ids, revoked.id
  end

  test "expired scope returns sessions past their expiry" do
    UserSession.create!(user: @user, expires_at: 1.day.from_now)
    expired = UserSession.create!(user: @user, expires_at: 1.hour.ago)

    assert_equal [ expired.id ], @user.user_sessions.expired.pluck(:id)
  end

  test "revoked scope returns sessions that have been revoked" do
    UserSession.create!(user: @user, expires_at: 1.day.from_now)
    revoked = UserSession.create!(user: @user, expires_at: 1.day.from_now, revoked_at: Time.current)

    assert_equal [ revoked.id ], @user.user_sessions.revoked.pluck(:id)
  end

  test "revoke! sets revoked_at" do
    session = UserSession.create!(user: @user, expires_at: 30.days.from_now)

    assert_nil session.revoked_at
    assert_predicate session, :active?

    session.revoke!

    assert_not_nil session.revoked_at
    assert_predicate session, :revoked?
    assert_not session.active?
  end

  test "active? returns false for expired sessions" do
    session = UserSession.create!(user: @user, expires_at: 1.second.ago)

    assert_not session.active?
  end

  test "requires expires_at" do
    session = UserSession.new(user: @user)

    assert_not session.valid?
    assert_includes session.errors[:expires_at], "can't be blank"
  end
end
# rubocop:enable Minitest/MultipleAssertions
