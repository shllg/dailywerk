# frozen_string_literal: true

require "concurrent/map"
require "concurrent/atomic/atomic_fixnum"

module Metrics
  # Stores lightweight in-process counters for Prometheus scraping.
  class Registry
    REQUEST_DURATION_BUCKETS = [ 0.05, 0.1, 0.25, 0.5, 1, 2, 5 ].freeze

    class << self
      # @param method [String]
      # @param controller [String, nil]
      # @param action [String, nil]
      # @param status [Integer]
      # @param duration_seconds [Float]
      # @return [void]
      def record_request(method:, controller:, action:, status:, duration_seconds:)
        labels = [
          method.to_s.upcase,
          controller.to_s.presence || "unknown",
          action.to_s.presence || "unknown",
          status.to_i.to_s
        ]

        counter(request_counts, labels).increment
        counter(request_duration_counts, labels).increment
        counter(request_duration_sums_ms, labels).update { |value| value + (duration_seconds * 1000).round }

        REQUEST_DURATION_BUCKETS.each do |bucket|
          next unless duration_seconds <= bucket

          counter(request_duration_buckets, labels + [ bucket_label(bucket) ]).increment
        end

        counter(request_duration_buckets, labels + [ "+Inf" ]).increment
      end

      # @return [void]
      def increment_action_cable_connections
        action_cable_connections.increment
      end

      # @return [void]
      def decrement_action_cable_connections
        action_cable_connections.update { |value| [ value - 1, 0 ].max }
      end

      # @return [Hash]
      def request_count_snapshot
        snapshot_counters(request_counts)
      end

      # @return [Hash]
      def request_duration_count_snapshot
        snapshot_counters(request_duration_counts)
      end

      # @return [Hash]
      def request_duration_sum_snapshot
        snapshot_counters(request_duration_sums_ms).transform_values { |value| value / 1000.0 }
      end

      # @return [Hash]
      def request_duration_bucket_snapshot
        snapshot_counters(request_duration_buckets)
      end

      # @return [Integer]
      def action_cable_connection_count
        action_cable_connections.value
      end

      private

      # @return [Concurrent::Map]
      def request_counts
        @request_counts ||= Concurrent::Map.new
      end

      # @return [Concurrent::Map]
      def request_duration_counts
        @request_duration_counts ||= Concurrent::Map.new
      end

      # @return [Concurrent::Map]
      def request_duration_sums_ms
        @request_duration_sums_ms ||= Concurrent::Map.new
      end

      # @return [Concurrent::Map]
      def request_duration_buckets
        @request_duration_buckets ||= Concurrent::Map.new
      end

      # @return [Concurrent::AtomicFixnum]
      def action_cable_connections
        @action_cable_connections ||= Concurrent::AtomicFixnum.new(0)
      end

      # @param bucket [Float]
      # @return [String]
      def bucket_label(bucket)
        format("%.2f", bucket)
      end

      # @param map [Concurrent::Map]
      # @param key [Array<String>]
      # @return [Concurrent::AtomicFixnum]
      def counter(map, key)
        map.fetch_or_store(key.freeze, Concurrent::AtomicFixnum.new(0))
      end

      # @param map [Concurrent::Map]
      # @return [Hash]
      def snapshot_counters(map)
        map.each_pair.with_object({}) do |(key, counter), snapshot|
          snapshot[key] = counter.value
        end
      end
    end
  end
end
