# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "normalizes email and returns the first workspace membership as default" do
    user = User.create!(
      email: "  SASCHA@DAILYWERK.COM  ",
      name: "Sascha",
      status: "active"
    )
    first_workspace = Workspace.create!(name: "Personal", owner: user)
    second_workspace = Workspace.create!(name: "Work", owner: user)

    WorkspaceMembership.create!(workspace: first_workspace, user:, role: "owner")
    WorkspaceMembership.create!(workspace: second_workspace, user:, role: "owner")

    assert_equal "sascha@dailywerk.com", user.email
    assert_equal first_workspace, user.default_workspace
  end

  test "requires a valid status" do
    user = User.new(email: "sascha@dailywerk.com", name: "Sascha", status: "paused")

    assert_not user.valid?
    assert_includes user.errors[:status], "is not included in the list"
  end

  test "does not allow changing workos_id once it has been set" do
    user = User.create!(
      email: "workos-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Sascha",
      status: "active",
      workos_id: "user_wos_#{SecureRandom.hex(4)}"
    )

    user.workos_id = "user_wos_#{SecureRandom.hex(4)}"

    assert_not user.valid?
    assert_includes user.errors[:workos_id], "cannot be changed once set"
  end
end
