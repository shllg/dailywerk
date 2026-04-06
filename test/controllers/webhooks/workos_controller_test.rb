# frozen_string_literal: true

require "test_helper"

# rubocop:disable Minitest/MultipleAssertions
class Webhooks::WorkosControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @webhook_secret = "whsec_test_#{SecureRandom.hex(16)}"
    @original_secret = ENV["WORKOS_WEBHOOK_SECRET"]
    ENV["WORKOS_WEBHOOK_SECRET"] = @webhook_secret

    @original_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  teardown do
    if @original_secret
      ENV["WORKOS_WEBHOOK_SECRET"] = @original_secret
    else
      ENV.delete("WORKOS_WEBHOOK_SECRET")
    end

    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @original_queue_adapter

    restore_verify_header
  end

  test "valid signature dispatches webhook job" do
    stub_verify_header_success

    payload = { event: "user.updated", data: { id: "user_123", email: "new@example.com" } }

    assert_enqueued_with(job: WorkosWebhookJob) do
      post "/webhooks/workos",
           params: payload.to_json,
           headers: webhook_headers("valid_signature")
    end

    assert_response :ok
  end

  test "missing signature returns 401" do
    post "/webhooks/workos",
         params: { event: "user.updated", data: {} }.to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  test "invalid signature returns 401" do
    stub_verify_header_failure

    post "/webhooks/workos",
         params: { event: "user.updated", data: {} }.to_json,
         headers: webhook_headers("invalid_signature")

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
