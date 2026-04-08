# frozen_string_literal: true

require "test_helper"

class ProductionEnvValidatorTest < ActiveSupport::TestCase
  # Simple struct-based config mock for testing
  GoodJobConfig = Struct.new(:basic_auth_username, :basic_auth_password, keyword_init: true)
  MetricsConfig = Struct.new(:enabled, :basic_auth_username, :basic_auth_password, keyword_init: true)
  ConfigX = Struct.new(:good_job, :metrics, keyword_init: true)
  MockConfig = Struct.new(:x, keyword_init: true)

  def mock_config(good_job_username: "goodjob", good_job_password: "secret",
                  metrics_enabled: true, metrics_username: "metrics", metrics_password: "secret")
    good_job = GoodJobConfig.new(
      basic_auth_username: good_job_username,
      basic_auth_password: good_job_password
    )
    metrics = MetricsConfig.new(
      enabled: metrics_enabled,
      basic_auth_username: metrics_username,
      basic_auth_password: metrics_password
    )
    MockConfig.new(x: ConfigX.new(good_job: good_job, metrics: metrics))
  end

  test "does nothing outside production" do
    assert_nil ProductionEnvValidator.validate!(
      env: {},
      rails_env: ActiveSupport::StringInquirer.new("development"),
      config: mock_config
    )
  end

  test "allows production boot when required config is present" do
    assert_nil(
      ProductionEnvValidator.validate!(
        env: { "CORS_ORIGINS" => "https://app.example.com" },
        rails_env: ActiveSupport::StringInquirer.new("production"),
        config: mock_config
      )
    )
  end

  test "allows blank metrics auth when metrics are disabled" do
    assert_nil(
      ProductionEnvValidator.validate!(
        env: { "CORS_ORIGINS" => "https://app.example.com" },
        rails_env: ActiveSupport::StringInquirer.new("production"),
        config: mock_config(metrics_enabled: false, metrics_username: nil, metrics_password: nil)
      )
    )
  end

  test "raises when cors origins are missing in production" do
    error = assert_raises(RuntimeError) do
      ProductionEnvValidator.validate!(
        env: {},
        rails_env: ActiveSupport::StringInquirer.new("production"),
        config: mock_config
      )
    end

    assert_equal "Missing required production env vars: CORS_ORIGINS", error.message
  end

  test "raises when good job auth is missing in production" do
    error = assert_raises(RuntimeError) do
      ProductionEnvValidator.validate!(
        env: { "CORS_ORIGINS" => "https://app.example.com" },
        rails_env: ActiveSupport::StringInquirer.new("production"),
        config: mock_config(good_job_password: nil)
      )
    end

    assert_equal "Missing required production env vars: GOOD_JOB_BASIC_AUTH_PASSWORD", error.message
  end

  test "raises when metrics auth is missing and metrics are enabled" do
    error = assert_raises(RuntimeError) do
      ProductionEnvValidator.validate!(
        env: { "CORS_ORIGINS" => "https://app.example.com" },
        rails_env: ActiveSupport::StringInquirer.new("production"),
        config: mock_config(metrics_password: nil)
      )
    end

    assert_equal "Missing required production env vars: METRICS_BASIC_AUTH_PASSWORD", error.message
  end
end
