# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class ProfileSynthesisJobTest < ActiveSupport::TestCase
  test "processes each workspace user with the correct Current context" do
    owner, workspace = create_user_with_workspace
    teammate = User.create!(
      email: "teammate-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Teammate",
      status: "active"
    )
    WorkspaceMembership.create!(workspace:, user: teammate, role: "member")

    observations = []
    failing_user_id = teammate.id

    original_constructor = ProfileSynthesisService.method(:new)
    fake_service_class = Struct.new(
      :user,
      :workspace,
      :observations,
      :failing_user_id,
      keyword_init: true
    ) do
      def call
        observations << {
          user_id: user.id,
          workspace_id: workspace.id,
          current_user_id: Current.user&.id,
          current_workspace_id: Current.workspace&.id
        }
        raise "boom" if user.id == failing_user_id
      end
    end

    ProfileSynthesisService.define_singleton_method(:new) do |user:, workspace:|
      fake_service_class.new(
        user:,
        workspace:,
        observations:,
        failing_user_id:
      )
    end

    silence_expected_logs do
      ProfileSynthesisJob.perform_now
    end

    workspace_observations = observations.select { |entry| entry[:workspace_id] == workspace.id }

    assert_equal [ owner.id, teammate.id ].sort, workspace_observations.map { |entry| entry[:user_id] }.sort
    workspace_observations.each do |entry|
      assert_equal entry[:user_id], entry[:current_user_id]
      assert_equal entry[:workspace_id], entry[:current_workspace_id]
    end
  ensure
    ProfileSynthesisService.define_singleton_method(:new, original_constructor)
  end
end
# rubocop:enable Minitest/MultipleAssertions
