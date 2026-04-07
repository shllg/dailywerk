# frozen_string_literal: true

# Exposes Prometheus metrics for app and worker-adjacent state.
class MetricsController < ActionController::API
  include ActionController::HttpAuthentication::Basic::ControllerMethods

  before_action :ensure_metrics_enabled!
  before_action :authenticate!

  # @return [void]
  def show
    render plain: Metrics::PrometheusExporter.new.call, content_type: Metrics::PrometheusExporter::CONTENT_TYPE
  end

  private

  # @return [void]
  def ensure_metrics_enabled!
    head :not_found unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("METRICS_ENABLED", "false"))
  end

  # @return [void]
  def authenticate!
    username = ENV["METRICS_BASIC_AUTH_USERNAME"].to_s
    password = ENV["METRICS_BASIC_AUTH_PASSWORD"].to_s
    if username.blank? || password.blank?
      return if !Rails.env.production? && username.blank? && password.blank?

      Rails.logger.error "Metrics endpoint misconfigured: basic auth credentials are required"
      return head :not_found
    end

    authenticate_or_request_with_http_basic("Metrics") do |provided_username, provided_password|
      ActiveSupport::SecurityUtils.secure_compare(provided_username, username) &&
        ActiveSupport::SecurityUtils.secure_compare(provided_password, password)
    end
  end
end
