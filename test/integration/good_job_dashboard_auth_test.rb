# frozen_string_literal: true

require "test_helper"

class GoodJobDashboardAuthTest < ActionDispatch::IntegrationTest
  setup do
    @previous_username = Rails.configuration.x.good_job.basic_auth_username
    @previous_password = Rails.configuration.x.good_job.basic_auth_password
    Rails.configuration.x.good_job.basic_auth_username = nil
    Rails.configuration.x.good_job.basic_auth_password = nil
  end

  teardown do
    Rails.configuration.x.good_job.basic_auth_username = @previous_username
    Rails.configuration.x.good_job.basic_auth_password = @previous_password
  end

  test "requires basic auth even when dashboard credentials are unset" do
    get "/good_job"

    assert_response :unauthorized
  end

  test "allows access with correct basic auth credentials" do
    Rails.configuration.x.good_job.basic_auth_username = "goodjob"
    Rails.configuration.x.good_job.basic_auth_password = "secret"

    credentials = ActionController::HttpAuthentication::Basic.encode_credentials("goodjob", "secret")
    get "/good_job", headers: { "Authorization" => credentials }

    assert_response :redirect
    assert_match(%r{/good_job/jobs(?:\?|$)}, response.redirect_url)
  end
end
