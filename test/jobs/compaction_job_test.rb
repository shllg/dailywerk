# frozen_string_literal: true

require "test_helper"

class CompactionJobTest < ActiveSupport::TestCase
  test "perform delegates to the compaction service" do
    user, workspace = create_user_with_workspace
    session = nil

    with_current_workspace(workspace, user:) do
      agent = Agent.create!(slug: "main", name: "DailyWerk", model_id: "gpt-5.4")
      session = Session.resolve(agent:)
    end

    fake_service = Object.new
    fake_service.define_singleton_method(:compact!) { { compacted: true, reason: "success" } }
    original_new = CompactionService.method(:new)
    captured_session_id = nil

    CompactionService.define_singleton_method(:new) do |passed_session|
      captured_session_id = passed_session.id
      fake_service
    end

    CompactionJob.perform_now(session.id, workspace_id: workspace.id)

    assert_equal session.id, captured_session_id
  ensure
    CompactionService.define_singleton_method(:new, original_new)
  end

  test "perform discards missing sessions" do
    user, workspace = create_user_with_workspace

    silence_expected_logs do
      assert_nothing_raised do
        CompactionJob.perform_now(SecureRandom.uuid, workspace_id: workspace.id)
      end
    end
  end
end
