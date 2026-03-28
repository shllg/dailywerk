# frozen_string_literal: true

require "test_helper"

module Api
  module V1
    class HealthControllerTest < ActionDispatch::IntegrationTest
      test "returns health status" do
        get api_v1_health_url

        assert_response :success

        json = JSON.parse(response.body)
        assert_equal "ok", json["status"]
        assert json["timestamp"].present?
        assert json["version"].present?
        assert json["ruby"].present?
      end
    end
  end
end
