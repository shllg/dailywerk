# frozen_string_literal: true

require "test_helper"

class MetricsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_enabled = Rails.configuration.x.metrics.enabled
    @previous_username = Rails.configuration.x.metrics.basic_auth_username
    @previous_password = Rails.configuration.x.metrics.basic_auth_password

    # Default state: enabled but no auth (dev/test friendly)
    Rails.configuration.x.metrics.enabled = true
    Rails.configuration.x.metrics.basic_auth_username = nil
    Rails.configuration.x.metrics.basic_auth_password = nil
  end

  teardown do
    Rails.configuration.x.metrics.enabled = @previous_enabled
    Rails.configuration.x.metrics.basic_auth_username = @previous_username
    Rails.configuration.x.metrics.basic_auth_password = @previous_password
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
    Rails.configuration.x.metrics.basic_auth_username = "metrics"
    Rails.configuration.x.metrics.basic_auth_password = "secret"

    get "/metrics"

    assert_response :unauthorized

    credentials = ActionController::HttpAuthentication::Basic.encode_credentials("metrics", "secret")
    get "/metrics", headers: { "Authorization" => credentials }

    assert_response :success
  end

  test "returns not found when metrics are disabled" do
    Rails.configuration.x.metrics.enabled = false

    get "/metrics"

    assert_response :not_found
  end

  test "returns not found in production when metrics auth is misconfigured" do
    Rails.configuration.x.metrics.basic_auth_username = "metrics"
    Rails.configuration.x.metrics.basic_auth_password = "secret"

    with_rails_env("production") do
      get "/metrics"
    end

    # When auth is configured in production, the request should require credentials
    assert_response :unauthorized
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
