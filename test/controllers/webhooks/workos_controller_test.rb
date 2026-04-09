# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class Webhooks::WorkosControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @webhook_secret = "whsec_test_#{SecureRandom.hex(16)}"
    @original_secret = Rails.configuration.x.workos.webhook_secret
    Rails.configuration.x.workos.webhook_secret = @webhook_secret

    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  teardown do
    Rails.configuration.x.workos.webhook_secret = @original_secret

    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter

    restore_verify_header
  end

  test "valid signature dispatches webhook job" do
    stub_verify_header_success

    payload = {
      event: "user.updated",
      data: {
        id: "user_123",
        email: "new@example.com",
        first_name: "New",
        role: "admin",
        profile: { admin: true }
      }
    }

    post "/webhooks/workos",
         params: payload.to_json,
         headers: webhook_headers("valid_signature")

    assert_response :ok

    assert_equal 1, enqueued_jobs.length
    job_args = enqueued_jobs.last[:args].first
    job_data = job_args["data"].except("_aj_hash_with_indifferent_access")

    assert_equal "user.updated", job_args["event_type"]
    assert_equal(
      {
        "id" => "user_123",
        "email" => "new@example.com",
        "first_name" => "New"
      },
      job_data
    )
  end

  test "missing signature returns 401" do
    silence_expected_logs do
      post "/webhooks/workos",
           params: { event: "user.updated", data: {} }.to_json,
           headers: { "Content-Type" => "application/json" }
    end

    assert_response :unauthorized
  end

  test "invalid signature returns 401" do
    stub_verify_header_failure

    silence_expected_logs do
      post "/webhooks/workos",
           params: { event: "user.updated", data: {} }.to_json,
           headers: webhook_headers("invalid_signature")
    end

    assert_response :unauthorized
  end

  private

  def webhook_headers(signature)
    {
      "Content-Type" => "application/json",
      "WorkOS-Signature" => signature
    }
  end

  def stub_verify_header_success
    @original_verify = WorkOS::Webhooks.method(:verify_header)
    WorkOS::Webhooks.define_singleton_method(:verify_header) do |**_kwargs|
      true
    end
  end

  def stub_verify_header_failure
    @original_verify = WorkOS::Webhooks.method(:verify_header)
    WorkOS::Webhooks.define_singleton_method(:verify_header) do |**_kwargs|
      raise WorkOS::SignatureVerificationError.new
    end
  end

  def restore_verify_header
    return unless @original_verify

    WorkOS::Webhooks.define_singleton_method(:verify_header, @original_verify)
    @original_verify = nil
  end
end
# rubocop:enable Minitest/MultipleAssertions
