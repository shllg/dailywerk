# frozen_string_literal: true

require "test_helper"

class ReadyControllerTest < ActionDispatch::IntegrationTest
  test "returns ok status when dependencies are healthy" do
    get "/ready"

    assert_response :success

    json = JSON.parse(response.body)

    assert_equal "ok", json["status"]
  end

  test "reports successful dependency checks when healthy" do
    get "/ready"

    assert_response :success

    json = JSON.parse(response.body)

    assert json.dig("checks", "database", "ok")
    assert json.dig("checks", "migrations", "ok")
  end

  test "returns service unavailable when valkey check fails" do
    with_env("VALKEY_URL" => "redis://127.0.0.1:1/0") do
      get "/ready"
    end

    assert_response :service_unavailable

    json = JSON.parse(response.body)

    assert_equal "error", json["status"]
    refute json.dig("checks", "valkey", "ok")
  end
end
