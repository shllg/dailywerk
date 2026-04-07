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

      test "returns a timestamp without runtime fingerprinting" do
        get api_v1_health_url

        json = JSON.parse(response.body)

        assert_predicate json["timestamp"], :present?
        refute_includes json.keys, "version"
        refute_includes json.keys, "ruby"
      end

      test "returns only the build sha metadata key" do
        get api_v1_health_url

        json = JSON.parse(response.body)

        assert_includes json.keys, "build_sha"
        refute_includes json.keys, "build_ref"
      end
    end
  end
end
