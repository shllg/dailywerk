# frozen_string_literal: true

require "test_helper"

class ApplicationJobTest < ActiveSupport::TestCase
  class WorkspaceContextProbeJob < ApplicationJob
    class_attribute :observations, default: []

    # @return [void]
    def perform
      self.class.observations = []

      each_workspace do |workspace|
        self.class.observations += [
          {
            workspace_id: workspace.id,
            current_workspace_id: Current.workspace&.id,
            db_workspace_id: ActiveRecord::Base.connection.select_value(
              "SELECT current_setting('app.current_workspace_id', true)"
            )
          }
        ]
      end
    end
  end

  test "each_workspace sets Current.workspace and the postgres workspace setting" do
    _user_one, workspace_one = create_user_with_workspace
    _user_two, workspace_two = create_user_with_workspace(
      email: "job-context-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )

    WorkspaceContextProbeJob.perform_now

    observations = WorkspaceContextProbeJob.observations.select do |entry|
      [ workspace_one.id, workspace_two.id ].include?(entry[:workspace_id])
    end

    assert_equal [ workspace_one.id, workspace_two.id ].sort, observations.map { |entry| entry[:workspace_id] }.sort
    observations.each do |entry|
      assert_equal entry[:workspace_id], entry[:current_workspace_id]
      assert_equal entry[:workspace_id], entry[:db_workspace_id]
    end
  end
end
