# frozen_string_literal: true

module Api
  module V1
    # Serializes structured memory entries and their audit history.
    class MemoryEntrySerializer
      class << self
        # @param entry [MemoryEntry]
        # @return [Hash]
        def summary(entry)
          {
            id: entry.id,
            category: entry.category,
            content: entry.content,
            source: entry.source,
            importance: entry.importance,
            confidence: entry.confidence.to_f.round(2),
            active: entry.active,
            visibility: entry.scope_label,
            fingerprint: entry.fingerprint,
            expires_at: entry.expires_at&.iso8601,
            access_count: entry.access_count,
            last_accessed_at: entry.last_accessed_at&.iso8601,
            updated_at: entry.updated_at.iso8601,
            metadata: json_hash(entry.metadata),
            agent: entry.agent && AgentSerializer.memory_scope(entry.agent),
            session_id: entry.session_id,
            source_message_id: entry.source_message_id
          }
        end

        # @param entry [MemoryEntry]
        # @return [Hash]
        def full(entry)
          summary(entry).merge(
            versions: entry.versions.limit(10).map { |version| serialize_version(version) }
          )
        end

        private

        # @param version [MemoryEntryVersion]
        # @return [Hash]
        def serialize_version(version)
          {
            id: version.id,
            action: version.action,
            reason: version.reason,
            created_at: version.created_at.iso8601,
            snapshot: json_value(version.snapshot)
          }
        end

        # @param value [Object]
        # @return [Hash]
        def json_hash(value)
          value.is_a?(Hash) ? value.deep_dup : {}
        end

        # @param value [Object]
        # @return [Object]
        def json_value(value)
          return value.deep_dup if value.is_a?(Hash) || value.is_a?(Array)

          value
        end
      end
    end
  end
end
