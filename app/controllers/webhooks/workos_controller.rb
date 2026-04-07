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
      payload = webhook_params
      event_type = payload[:event]
      event_data = payload[:data] || {}

      Rails.logger.info "WorkOS webhook received: #{event_type}"

      WorkosWebhookJob.perform_later(
        event_type:,
        data: event_data.to_h.deep_stringify_keys
      )

      head :ok
    rescue StandardError => e
      Rails.logger.error "WorkOS webhook processing failed: #{e.message}"
      head :ok # Always return 200 to prevent retries on our errors
    end

    private

    # @return [ActionController::Parameters]
    def webhook_params
      case params[:event]
      when "user.updated"
        params.permit(:event, data: %i[id email first_name last_name])
      when "user.deleted"
        params.permit(:event, data: [ :id ])
      else
        params.permit(:event)
      end
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
