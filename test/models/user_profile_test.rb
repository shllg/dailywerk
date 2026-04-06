# frozen_string_literal: true

require "test_helper"

class UserProfileTest < ActiveSupport::TestCase
  test "enforces unique user-workspace pair" do
    user, workspace = create_user_with_workspace

    with_current_workspace(workspace, user:) do
      UserProfile.create!(user:, workspace:, synthesized_profile: "First profile")

      duplicate = UserProfile.new(user:, workspace:, synthesized_profile: "Second profile")

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:user_id], "has already been taken"
    end
  end
end
