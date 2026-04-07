# frozen_string_literal: true

require "test_helper"

class GoodJobDashboardAuthTest < ActionDispatch::IntegrationTest
  setup do
    @previous_username = ENV["GOOD_JOB_BASIC_AUTH_USERNAME"]
    @previous_password = ENV["GOOD_JOB_BASIC_AUTH_PASSWORD"]
    ENV["GOOD_JOB_BASIC_AUTH_USERNAME"] = ""
    ENV["GOOD_JOB_BASIC_AUTH_PASSWORD"] = ""
  end

  teardown do
    ENV["GOOD_JOB_BASIC_AUTH_USERNAME"] = @previous_username
    ENV["GOOD_JOB_BASIC_AUTH_PASSWORD"] = @previous_password
  end

  test "requires basic auth even when dashboard credentials are unset" do
    get "/good_job"

    assert_response :unauthorized
  end

  test "allows access with correct basic auth credentials" do
    ENV["GOOD_JOB_BASIC_AUTH_USERNAME"] = "goodjob"
    ENV["GOOD_JOB_BASIC_AUTH_PASSWORD"] = "secret"

    credentials = ActionController::HttpAuthentication::Basic.encode_credentials("goodjob", "secret")
    get "/good_job", headers: { "Authorization" => credentials }

    assert_response :redirect
    assert_match(%r{/good_job/jobs(?:\?|$)}, response.redirect_url)
  end
end
