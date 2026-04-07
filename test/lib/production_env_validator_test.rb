# frozen_string_literal: true

require "test_helper"

class ProductionEnvValidatorTest < ActiveSupport::TestCase
  test "does nothing outside production" do
    assert_nil ProductionEnvValidator.validate!(env: {}, rails_env: ActiveSupport::StringInquirer.new("development"))
  end

  test "allows production boot when required env vars are present" do
    assert_nil(
      ProductionEnvValidator.validate!(
        env: valid_env,
        rails_env: ActiveSupport::StringInquirer.new("production")
      )
    )
  end

  test "allows blank metrics auth when metrics are disabled" do
    assert_nil(
      ProductionEnvValidator.validate!(
        env: valid_env.merge(
          "METRICS_ENABLED" => "false",
          "METRICS_BASIC_AUTH_USERNAME" => "",
          "METRICS_BASIC_AUTH_PASSWORD" => ""
        ),
        rails_env: ActiveSupport::StringInquirer.new("production")
      )
    )
  end

  test "raises when cors origins are missing in production" do
    error = assert_raises(RuntimeError) do
      ProductionEnvValidator.validate!(
        env: valid_env.except("CORS_ORIGINS"),
        rails_env: ActiveSupport::StringInquirer.new("production")
      )
    end

    assert_equal "Missing required production env vars: CORS_ORIGINS", error.message
  end

  test "raises when good job auth is missing in production" do
    error = assert_raises(RuntimeError) do
      ProductionEnvValidator.validate!(
        env: valid_env.merge("GOOD_JOB_BASIC_AUTH_PASSWORD" => ""),
        rails_env: ActiveSupport::StringInquirer.new("production")
      )
    end

    assert_equal "Missing required production env vars: GOOD_JOB_BASIC_AUTH_PASSWORD", error.message
  end

  test "raises when metrics auth is missing and metrics are enabled" do
    error = assert_raises(RuntimeError) do
      ProductionEnvValidator.validate!(
        env: valid_env.merge("METRICS_BASIC_AUTH_PASSWORD" => ""),
        rails_env: ActiveSupport::StringInquirer.new("production")
      )
    end

    assert_equal "Missing required production env vars: METRICS_BASIC_AUTH_PASSWORD", error.message
  end

  private

  def valid_env
    {
      "CORS_ORIGINS" => "https://app.example.com",
      "GOOD_JOB_BASIC_AUTH_USERNAME" => "goodjob",
      "GOOD_JOB_BASIC_AUTH_PASSWORD" => "secret",
      "METRICS_ENABLED" => "true",
      "METRICS_BASIC_AUTH_USERNAME" => "metrics",
      "METRICS_BASIC_AUTH_PASSWORD" => "secret"
    }
  end
end
