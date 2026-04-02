# frozen_string_literal: true

module Metrics
  # Captures request logs and lightweight request metrics for Prometheus.
  class RequestMiddleware
    def initialize(app)
      @app = app
    end

    # @param env [Hash]
    # @return [Array(Integer, Hash, #each)]
    def call(env)
      request = ActionDispatch::Request.new(env)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Current.request_id = request.request_id

      status, headers, body = rack_response(@app.call(env))
      log_request(request:, env:, status:, started_at:)

      [ status, headers, body ]
    rescue StandardError => error
      log_request(request:, env:, status: 500, started_at:, error:)
      raise
    ensure
      Current.request_id = nil
    end

    private

    # @param response [Array, #to_a]
    # @return [Array(Integer, Hash, #each)]
    def rack_response(response)
      return response if response.is_a?(Array)

      response.to_a
    end

    # @param request [ActionDispatch::Request]
    # @param env [Hash]
    # @param status [Integer]
    # @param started_at [Float]
    # @param error [Exception, nil]
    # @return [void]
    def log_request(request:, env:, status:, started_at:, error: nil)
      duration_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      path_parameters = env["action_dispatch.request.path_parameters"] || {}
      controller = path_parameters[:controller] || path_parameters["controller"]
      action = path_parameters[:action] || path_parameters["action"]

      Registry.record_request(
        method: request.request_method,
        controller: controller,
        action: action,
        status:,
        duration_seconds:
      )

      payload = {
        event: "request",
        request_id: request.request_id,
        method: request.request_method,
        path: request.fullpath,
        controller: controller,
        action: action,
        status:,
        duration_ms: (duration_seconds * 1000).round(1)
      }

      if error
        payload[:error_class] = error.class.name
        payload[:error_message] = error.message
        Rails.logger.error(payload)
      else
        Rails.logger.info(payload)
      end
    end
  end
end
