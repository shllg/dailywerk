# frozen_string_literal: true

require "test_helper"

module Api
  module V1
    class SessionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @user = User.create!(
          email: "sessions-#{SecureRandom.hex(4)}@dailywerk.com",
          name: "Sascha",
          status: "active"
        )
        @workspace = Workspace.create!(name: "Personal", owner: @user)
        WorkspaceMembership.create!(workspace: @workspace, user: @user, role: "owner")
      end

      # rubocop:disable Minitest/MultipleAssertions
      test "creates a fake session for an active user" do
        post api_v1_sessions_url,
             params: { session: { email: @user.email.upcase } },
             as: :json

        assert_response :success

        json = JSON.parse(response.body)

        assert_predicate json["token"], :present?
        assert_equal @user.id, json.dig("user", "id")
        assert_equal @workspace.id, json.dig("workspace", "id")
      end

      test "returns user and workspace metadata in the fake session response" do
        post api_v1_sessions_url,
             params: { session: { email: @user.email } },
             as: :json

        assert_response :success

        json = JSON.parse(response.body)

        assert_equal @user.email, json.dig("user", "email")
        assert_equal "Sascha", json.dig("user", "name")
        assert_equal @workspace.name, json.dig("workspace", "name")
      end
      # rubocop:enable Minitest/MultipleAssertions

      test "rejects unknown users" do
        post api_v1_sessions_url,
             params: { session: { email: "missing@dailywerk.com" } },
             as: :json

        assert_response :unauthorized
        assert_equal "User not found", JSON.parse(response.body)["error"]
      end

      test "health remains publicly accessible" do
        get api_v1_health_url

        assert_response :success
      end
    end
  end
end
