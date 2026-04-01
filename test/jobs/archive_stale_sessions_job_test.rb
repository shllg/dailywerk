# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

# rubocop:disable Minitest/MultipleAssertions
class ArchiveStaleSessionsJobTest < ActiveSupport::TestCase
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

  test "archives stale sessions across workspaces and skips active ones" do
    user_one, workspace_one = create_user_with_workspace
    user_two, workspace_two = create_user_with_workspace(
      email: "other-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )

    stale_session_one = with_current_workspace(workspace_one, user: user_one) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      session.messages.create!(role: "user", content: "Need summary")
      session.update!(last_activity_at: 8.days.ago)
      session
    end

    stale_session_two = with_current_workspace(workspace_two, user: user_two) do
      agent = Agent.create!(slug: "main", name: "Other", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      session.update!(last_activity_at: 9.days.ago, summary: "Already summarized")
      session
    end

    active_session = with_current_workspace(workspace_one, user: user_one) do
      agent = Agent.create!(slug: "active", name: "Active", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
      session.update!(last_activity_at: 1.hour.ago)
      session
    end

    assert_enqueued_jobs 1, only: CompactionJob do
      ArchiveStaleSessionsJob.perform_now
    end

    Current.without_workspace_scoping do
      assert_equal "archived", stale_session_one.reload.status
      assert_equal "archived", stale_session_two.reload.status
      assert_equal "active", active_session.reload.status
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
