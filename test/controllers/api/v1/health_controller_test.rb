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
      end

      test "returns runtime version info" do
        get api_v1_health_url

        json = JSON.parse(response.body)

        assert_predicate json["timestamp"], :present?
        assert_predicate json["version"], :present?
        assert_predicate json["ruby"], :present?
      end

      test "returns build metadata keys" do
        get api_v1_health_url

        json = JSON.parse(response.body)

        assert_includes json.keys, "build_sha"
        assert_includes json.keys, "build_ref"
      end
    end
  end
end
