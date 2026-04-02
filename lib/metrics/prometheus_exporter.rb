# frozen_string_literal: true

module Metrics
  # Renders a Prometheus exposition payload for app, DB, and job metrics.
  class PrometheusExporter
    CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

    # @return [String]
    def call
      lines = []
      append_build_info(lines)
      append_request_metrics(lines)
      append_action_cable_metrics(lines)
      append_database_pool_metrics(lines)
      append_good_job_metrics(lines)
      lines.join("\n") << "\n"
    end

    private

    # @param lines [Array<String>]
    # @return [void]
    def append_build_info(lines)
      lines << "# HELP dailywerk_build_info Build metadata for the running app."
      lines << "# TYPE dailywerk_build_info gauge"
      lines << %(dailywerk_build_info{sha="#{label_value(ENV.fetch("BUILD_SHA", "unknown"))}",ref="#{label_value(ENV.fetch("BUILD_REF", "unknown"))}",environment="#{label_value(ENV.fetch("APP_ENVIRONMENT", Rails.env))}"} 1)
    end

    # @param lines [Array<String>]
    # @return [void]
    def append_request_metrics(lines)
      lines << "# HELP dailywerk_http_requests_total Total HTTP requests observed by the API process."
      lines << "# TYPE dailywerk_http_requests_total counter"
      Registry.request_count_snapshot.each do |labels, value|
        lines << metric_line("dailywerk_http_requests_total", request_labels(labels), value)
      end

      lines << "# HELP dailywerk_http_request_duration_seconds HTTP request duration buckets."
      lines << "# TYPE dailywerk_http_request_duration_seconds histogram"
      Registry.request_duration_bucket_snapshot.each do |labels, value|
        lines << metric_line("dailywerk_http_request_duration_seconds_bucket", request_labels(labels.first(4)).merge(le: labels[4]), value)
      end
      Registry.request_duration_count_snapshot.each do |labels, value|
        lines << metric_line("dailywerk_http_request_duration_seconds_count", request_labels(labels), value)
      end
      Registry.request_duration_sum_snapshot.each do |labels, value|
        lines << metric_line("dailywerk_http_request_duration_seconds_sum", request_labels(labels), value)
      end
    end

    # @param lines [Array<String>]
    # @return [void]
    def append_action_cable_metrics(lines)
      lines << "# HELP dailywerk_action_cable_connections Current Action Cable connections for this API process."
      lines << "# TYPE dailywerk_action_cable_connections gauge"
      lines << metric_line("dailywerk_action_cable_connections", {}, Registry.action_cable_connection_count)
    end

    # @param lines [Array<String>]
    # @return [void]
    def append_database_pool_metrics(lines)
      stats = ActiveRecord::Base.connection_pool.stat.transform_keys(&:to_s)

      lines << "# HELP dailywerk_active_record_pool Active Record pool state for this API process."
      lines << "# TYPE dailywerk_active_record_pool gauge"
      %w[size connections busy dead idle waiting].each do |state|
        lines << metric_line("dailywerk_active_record_pool", { state: }, stats.fetch(state, 0))
      end
    end

    # @param lines [Array<String>]
    # @return [void]
    def append_good_job_metrics(lines)
      lines << "# HELP dailywerk_good_job_queue_depth Unfinished GoodJob jobs by queue and state."
      lines << "# TYPE dailywerk_good_job_queue_depth gauge"

      GoodJob::Job.queued.group(:queue_name).count.each do |queue_name, count|
        lines << metric_line("dailywerk_good_job_queue_depth", { queue: queue_name.presence || "default", state: "queued" }, count)
      end

      GoodJob::Job.running.group(:queue_name).count.each do |queue_name, count|
        lines << metric_line("dailywerk_good_job_queue_depth", { queue: queue_name.presence || "default", state: "running" }, count)
      end
    end

    # @param labels [Array<String>]
    # @return [Hash]
    def request_labels(labels)
      {
        method: labels[0],
        controller: labels[1],
        action: labels[2],
        status: labels[3]
      }
    end

    # @param name [String]
    # @param labels [Hash]
    # @param value [Numeric]
    # @return [String]
    def metric_line(name, labels, value)
      formatted_labels =
        if labels.empty?
          ""
        else
          "{" + labels.map { |key, label| %(#{key}="#{label_value(label)}") }.join(",") + "}"
        end

      "#{name}#{formatted_labels} #{value}"
    end

    # @param value [Object]
    # @return [String]
    def label_value(value)
      value.to_s.gsub("\\", "\\\\").gsub("\"", "\\\"").gsub("\n", "\\n")
    end
  end
end
