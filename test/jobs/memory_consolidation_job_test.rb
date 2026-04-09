# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class MemoryConsolidationJobTest < ActiveSupport::TestCase
  test "processes every workspace with RLS context and continues after failures" do
    _user_one, workspace_one = create_user_with_workspace
    _user_two, workspace_two = create_user_with_workspace(
      email: "memory-consolidation-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )
    observations = []
    failing_workspace_id = workspace_two.id

    original_constructor = MemoryConsolidationService.method(:new)
    fake_service_class = Struct.new(
      :workspace,
      :observations,
      :failing_workspace_id,
      keyword_init: true
    ) do
      def call
        observations << {
          workspace_id: workspace.id,
          current_workspace_id: Current.workspace&.id,
          db_workspace_id: ActiveRecord::Base.connection.select_value(
            "SELECT current_setting('app.current_workspace_id', true)"
          )
        }
        raise "boom" if workspace.id == failing_workspace_id

        {
          promoted: 1,
          discarded: 0,
          superseded: 0,
          decayed: 0,
          bumped: 0
        }
      end
    end

    MemoryConsolidationService.define_singleton_method(:new) do |workspace:|
      fake_service_class.new(
        workspace:,
        observations:,
        failing_workspace_id:
      )
    end

    silence_expected_logs do
      MemoryConsolidationJob.perform_now
    end

    created_workspace_ids = [ workspace_one.id, workspace_two.id ]
    created_observations = observations.select { |entry| created_workspace_ids.include?(entry[:workspace_id]) }

    assert_equal(
      created_workspace_ids.sort,
      created_observations.map { |entry| entry[:workspace_id] }.sort
    )
    created_observations.each do |entry|
      assert_equal entry[:workspace_id], entry[:current_workspace_id]
      assert_equal entry[:workspace_id], entry[:db_workspace_id]
    end
  ensure
    MemoryConsolidationService.define_singleton_method(:new, original_constructor)
  end
end
# rubocop:enable Minitest/MultipleAssertions
