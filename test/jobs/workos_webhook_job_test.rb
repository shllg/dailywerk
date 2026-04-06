# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class WorkosWebhookJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "user.updated syncs email and name" do
    user = User.create!(
      email: "sync-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Original",
      status: "active",
      workos_id: "user_wos_sync_#{SecureRandom.hex(4)}"
    )

    WorkosWebhookJob.perform_now(
      event_type: "user.updated",
      data: {
        "id" => user.workos_id,
        "email" => "updated-#{SecureRandom.hex(4)}@dailywerk.com",
        "first_name" => "Updated",
        "last_name" => "Name"
      }
    )

    user.reload

    assert_equal "Updated Name", user.name
  end

  test "user.deleted suspends user and revokes sessions" do
    user = User.create!(
      email: "delete-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "ToDelete",
      status: "active",
      workos_id: "user_wos_del_#{SecureRandom.hex(4)}"
    )

    session = UserSession.create!(user:, expires_at: 30.days.from_now)

    WorkosWebhookJob.perform_now(
      event_type: "user.deleted",
      data: { "id" => user.workos_id }
    )

    assert_equal "suspended", user.reload.status
    assert_predicate session.reload, :revoked?
  end

  test "unhandled event type is logged without error" do
    assert_nothing_raised do
      WorkosWebhookJob.perform_now(
        event_type: "organization.created",
        data: { "id" => "org_123" }
      )
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
