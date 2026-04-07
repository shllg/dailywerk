# frozen_string_literal: true

require "test_helper"

class CorsOriginsTest < ActiveSupport::TestCase
  test "parses comma-separated origins" do
    env = { "CORS_ORIGINS" => "https://app.example.com, https://admin.example.com" }
    rails_env = ActiveSupport::StringInquirer.new("production")

    assert_equal(
      [ "https://app.example.com", "https://admin.example.com" ],
      CorsOrigins.load!(env:, rails_env:)
    )
  end

  test "falls back to localhost outside production" do
    env = {}
    rails_env = ActiveSupport::StringInquirer.new("development")

    assert_equal [ "http://localhost:5173" ], CorsOrigins.load!(env:, rails_env:)
  end

  test "raises when origins are missing in production" do
    env = {}
    rails_env = ActiveSupport::StringInquirer.new("production")

    error = assert_raises(RuntimeError) do
      CorsOrigins.load!(env:, rails_env:)
    end

    assert_equal "CORS_ORIGINS must be configured in production", error.message
  end
end
