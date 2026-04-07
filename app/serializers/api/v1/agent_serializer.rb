# frozen_string_literal: true

module Api
  module V1
    # Serializes agent payloads for API responses.
    class AgentSerializer
      class << self
        # @param agent [Agent]
        # @return [Hash]
        def summary(agent)
          {
            id: agent.id,
            slug: agent.slug,
            name: agent.name
          }
        end

        # @param agent [Agent]
        # @return [Hash]
        def memory_scope(agent)
          summary(agent).merge(
            memory_isolation: agent.memory_isolation
          )
        end

        # @param agent [Agent]
        # @return [Hash]
        def full(agent)
          summary(agent).merge(
            model_id: agent.model_id,
            memory_isolation: agent.memory_isolation,
            provider: agent.provider,
            temperature: agent.temperature,
            instructions: agent.instructions,
            soul: agent.soul,
            identity: json_hash(agent.identity),
            params: json_hash(agent.params),
            thinking: json_hash(agent.thinking),
            tool_names: Array(agent.tool_names).dup,
            is_default: agent.is_default,
            active: agent.active
          )
        end

        private

        # @param value [Object]
        # @return [Hash]
        def json_hash(value)
          value.is_a?(Hash) ? value.deep_dup : {}
        end
      end
    end
  end
end
