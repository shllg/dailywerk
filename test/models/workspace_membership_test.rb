# frozen_string_literal: true

require "test_helper"

class WorkspaceMembershipTest < ActiveSupport::TestCase
  test "prevents duplicate memberships for the same user and workspace" do
    user = User.create!(email: "membership-#{SecureRandom.hex(4)}@dailywerk.com", name: "Sascha", status: "active")
    workspace = Workspace.create!(name: "Personal", owner: user)

    WorkspaceMembership.create!(workspace:, user:, role: "owner")
    duplicate = WorkspaceMembership.new(workspace:, user:, role: "member")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "requires a known role" do
    user = User.create!(email: "membership-role-#{SecureRandom.hex(4)}@dailywerk.com", name: "Sascha", status: "active")
    workspace = Workspace.create!(name: "Personal", owner: user)
    membership = WorkspaceMembership.new(workspace:, user:, role: "guest")

    assert_not membership.valid?
    assert_includes membership.errors[:role], "is not included in the list"
  end
end
