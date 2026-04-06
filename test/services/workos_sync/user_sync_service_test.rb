# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class WorkosSync::UserSyncServiceTest < ActiveSupport::TestCase
  test "updates email when changed" do
    user = User.create!(
      email: "old-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Sync Test",
      status: "active",
      workos_id: "user_sync_email_#{SecureRandom.hex(4)}"
    )

    new_email = "new-#{SecureRandom.hex(4)}@dailywerk.com"

    WorkosSync::UserSyncService.new(
      "id" => user.workos_id,
      "email" => new_email,
      "first_name" => "Sync",
      "last_name" => "Test"
    ).call

    assert_equal new_email, user.reload.email
  end

  test "updates name when changed" do
    user = User.create!(
      email: "name-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Old Name",
      status: "active",
      workos_id: "user_sync_name_#{SecureRandom.hex(4)}"
    )

    WorkosSync::UserSyncService.new(
      "id" => user.workos_id,
      "email" => user.email,
      "first_name" => "New",
      "last_name" => "Name"
    ).call

    assert_equal "New Name", user.reload.name
  end

  test "no-op when nothing changed" do
    user = User.create!(
      email: "noop-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Same Name",
      status: "active",
      workos_id: "user_sync_noop_#{SecureRandom.hex(4)}"
    )

    original_updated_at = user.updated_at

    WorkosSync::UserSyncService.new(
      "id" => user.workos_id,
      "email" => user.email,
      "first_name" => "Same",
      "last_name" => "Name"
    ).call

    assert_equal original_updated_at, user.reload.updated_at
  end

  test "handles unknown workos_id gracefully" do
    assert_nothing_raised do
      WorkosSync::UserSyncService.new(
        "id" => "user_nonexistent_#{SecureRandom.hex(4)}",
        "email" => "nobody@example.com",
        "first_name" => "Nobody",
        "last_name" => ""
      ).call
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
