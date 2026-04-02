# frozen_string_literal: true

require "json"

# Formats application logs as JSON lines for container log collectors.
class StructuredLogFormatter < Logger::Formatter
  # @param severity [String]
  # @param timestamp [Time]
  # @param progname [String, nil]
  # @param message [Object]
  # @return [String]
  def call(severity, timestamp, progname, message)
    payload = normalize_message(message).merge(
      severity:,
      timestamp: timestamp.utc.iso8601(6),
      environment: ENV.fetch("APP_ENVIRONMENT", Rails.env)
    )

    payload[:progname] = progname if progname.present?
    payload[:request_id] ||= Current.request_id if defined?(Current)

    "#{payload.compact.to_json}\n"
  end

  private

  # @param message [Object]
  # @return [Hash]
  def normalize_message(message)
    case message
    when Hash
      message.deep_dup
    when Exception
      {
        message: message.message,
        error_class: message.class.name,
        backtrace: message.backtrace
      }
    else
      { message: message.to_s }
    end
  end
end
