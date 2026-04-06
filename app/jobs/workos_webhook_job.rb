# frozen_string_literal: true

# Routes WorkOS webhook events to the appropriate sync service.
#
# Cross-workspace job — webhooks are not scoped to a single workspace.
# Always returns 200 to the webhook controller to prevent WorkOS retries
# on application errors; failures are logged and retried by GoodJob.
class WorkosWebhookJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  # @param event_type [String] the WorkOS event type (e.g. "user.updated")
  # @param data [Hash] permitted event data
  # @return [void]
  def perform(event_type:, data:)
    case event_type
    when "user.updated"
      WorkosSync::UserSyncService.new(data).call
    when "user.deleted"
      handle_user_deleted(data)
    else
      Rails.logger.info "WorkosWebhookJob: unhandled event type: #{event_type}"
    end
  end

  private

  # Suspends the user and revokes all active sessions.
  #
  # @param data [Hash]
  # @return [void]
  def handle_user_deleted(data)
    user = User.find_by(workos_id: data["id"])
    return unless user

    user.update!(status: "suspended")
    user.user_sessions.active.find_each(&:revoke!)

    Rails.logger.info "WorkosWebhookJob: suspended user #{user.id} (WorkOS #{data['id']} deleted)"
  end
end
