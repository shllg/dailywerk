# frozen_string_literal: true

module Webhooks
  # Receives and verifies WorkOS webhook events.
  #
  # Signature verification uses the WorkOS SDK's built-in HMAC-SHA256
  # check with timestamp tolerance (rejects events older than 5 minutes).
  # Valid events are dispatched to WorkosWebhookJob for background processing.
  class WorkosController < ActionController::API
    TIMESTAMP_TOLERANCE = 300 # 5 minutes

    before_action :verify_webhook_signature

    # POST /webhooks/workos
    #
    # @return [void]
    def handle
      event_type = webhook_params[:event]
      event_data = webhook_params[:data]

      Rails.logger.info "WorkOS webhook received: #{event_type}"

      WorkosWebhookJob.perform_later(
        event_type:,
        data: permitted_event_data(event_data)
      )

      head :ok
    rescue StandardError => e
      Rails.logger.error "WorkOS webhook processing failed: #{e.message}"
      head :ok # Always return 200 to prevent retries on our errors
    end

    private

    # @return [ActionController::Parameters]
    def webhook_params
      params.permit(:event, data: {})
    end

    # Extracts permitted fields from the event data.
    #
    # @param data [ActionController::Parameters]
    # @return [Hash]
    def permitted_event_data(data)
      data.permit(
        :id, :email, :first_name, :last_name,
        :email_verified, :profile_picture_url,
        :created_at, :updated_at
      ).to_h
    end

    # Verifies the WorkOS webhook signature using the SDK.
    # Rejects events with invalid signatures or timestamps older than 5 minutes.
    #
    # @return [void]
    def verify_webhook_signature
      payload = request.raw_post
      sig_header = request.headers["WorkOS-Signature"]

      if sig_header.blank?
        Rails.logger.warn "WorkOS webhook: missing signature header"
        return head :unauthorized
      end

      secret = ENV["WORKOS_WEBHOOK_SECRET"]
      if secret.blank?
        Rails.logger.error "WorkOS webhook: WORKOS_WEBHOOK_SECRET not configured"
        return head :internal_server_error
      end

      WorkOS::Webhooks.verify_header(
        payload:,
        sig_header:,
        secret:,
        tolerance: TIMESTAMP_TOLERANCE
      )
    rescue WorkOS::SignatureVerificationError => e
      Rails.logger.warn "WorkOS webhook: signature verification failed: #{e.message}"
      head :unauthorized
    end
  end
end
