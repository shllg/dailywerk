# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

class VaultS3SyncAllJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter
  end

  test "enqueues one sync job per active vault" do
    user_one, workspace_one = create_user_with_workspace
    user_two, workspace_two = create_user_with_workspace(
      email: "vault-sync-all-#{SecureRandom.hex(4)}@dailywerk.com",
      workspace_name: "Other"
    )

    active_one = nil
    active_two = nil

    with_current_workspace(workspace_one, user: user_one) do
      active_one = Vault.create!(
        name: "Active One",
        slug: "active-one-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
      Vault.create!(
        name: "Inactive One",
        slug: "inactive-one-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "suspended"
      )
    end

    with_current_workspace(workspace_two, user: user_two) do
      active_two = Vault.create!(
        name: "Active Two",
        slug: "active-two-#{SecureRandom.hex(4)}",
        vault_type: "native",
        status: "active"
      )
    end

    VaultS3SyncAllJob.perform_now

    sync_jobs = enqueued_jobs.select { |job| job[:job] == VaultS3SyncJob }
    sync_args = sync_jobs.map do |job|
      [ job[:args][0], job[:args][1]["workspace_id"] ]
    end

    assert_equal 2, sync_jobs.size
    assert_includes sync_args, [ active_one.id, workspace_one.id ]
    assert_includes sync_args, [ active_two.id, workspace_two.id ]
  end
end
