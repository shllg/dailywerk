# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class WorkosSessionCleanupJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(
      email: "cleanup-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Cleanup",
      status: "active"
    )

    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "deletes expired sessions older than 30 days" do
    old_expired = UserSession.create!(user: @user, expires_at: 60.days.ago)
    recent_expired = UserSession.create!(user: @user, expires_at: 1.day.ago)
    active = UserSession.create!(user: @user, expires_at: 30.days.from_now)

    WorkosSessionCleanupJob.perform_now

    assert_not UserSession.exists?(old_expired.id)
    assert UserSession.exists?(recent_expired.id)
    assert UserSession.exists?(active.id)
  end

  test "deletes revoked sessions older than 30 days" do
    old_revoked = UserSession.create!(user: @user, expires_at: 1.year.from_now, revoked_at: 60.days.ago)
    recent_revoked = UserSession.create!(user: @user, expires_at: 1.year.from_now, revoked_at: 1.day.ago)

    WorkosSessionCleanupJob.perform_now

    assert_not UserSession.exists?(old_revoked.id)
    assert UserSession.exists?(recent_revoked.id)
  end

  test "keeps active sessions untouched" do
    active = UserSession.create!(user: @user, expires_at: 30.days.from_now)

    WorkosSessionCleanupJob.perform_now

    assert UserSession.exists?(active.id)
  end
end
# rubocop:enable Minitest/MultipleAssertions
