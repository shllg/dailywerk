# frozen_string_literal: true

require "test_helper"

class MetricsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_enabled = ENV["METRICS_ENABLED"]
    @previous_username = ENV["METRICS_BASIC_AUTH_USERNAME"]
    @previous_password = ENV["METRICS_BASIC_AUTH_PASSWORD"]
    ENV["METRICS_ENABLED"] = "true"
    ENV["METRICS_BASIC_AUTH_USERNAME"] = ""
    ENV["METRICS_BASIC_AUTH_PASSWORD"] = ""
  end

  teardown do
    ENV["METRICS_ENABLED"] = @previous_enabled
    ENV["METRICS_BASIC_AUTH_USERNAME"] = @previous_username
    ENV["METRICS_BASIC_AUTH_PASSWORD"] = @previous_password
  end

  test "returns a successful response when metrics are enabled" do
    get "/metrics"

    assert_response :success
  end

  test "includes build info in the prometheus payload when enabled" do
    get "/metrics"

    assert_response :success

    assert_includes response.media_type, "text/plain"
    assert_includes response.body, "dailywerk_build_info"
  end

  test "includes active record pool metrics in the prometheus payload when enabled" do
    get "/metrics"

    assert_response :success

    assert_includes response.body, "dailywerk_active_record_pool"
  end

  test "requires basic auth when configured" do
    ENV["METRICS_BASIC_AUTH_USERNAME"] = "metrics"
    ENV["METRICS_BASIC_AUTH_PASSWORD"] = "secret"

    get "/metrics"

    assert_response :unauthorized

    credentials = ActionController::HttpAuthentication::Basic.encode_credentials("metrics", "secret")
    get "/metrics", headers: { "Authorization" => credentials }

    assert_response :success
  end

  test "returns not found when metrics are disabled" do
    ENV["METRICS_ENABLED"] = "false"

    get "/metrics"

    assert_response :not_found
  end

  test "returns not found in production when metrics auth is misconfigured" do
    with_rails_env("production") do
      get "/metrics"
    end

    assert_response :not_found
  end

  private

  def with_rails_env(name)
    original_env = Rails.method(:env)
    Rails.define_singleton_method(:env) do
      ActiveSupport::StringInquirer.new(name)
    end

    yield
  ensure
    Rails.define_singleton_method(:env, original_env)
  end
end
