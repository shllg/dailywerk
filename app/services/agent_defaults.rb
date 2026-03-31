# frozen_string_literal: true

# Provides factory-default values for agent configuration.
class AgentDefaults
  VALUES = {
    slug: "main",
    name: "DailyWerk",
    model_id: "gpt-5.4",
    provider: nil,
    temperature: 0.7,
    instructions: <<~PROMPT.strip,
      You are DailyWerk, a helpful personal AI assistant.
      Be concise, friendly, and direct. Use markdown for formatting when helpful.
      If you don't know something, say so honestly.
    PROMPT
    soul: nil,
    identity: {}.freeze,
    params: {}.freeze,
    thinking: {}.freeze
  }.freeze

  CONFIGURABLE_FIELDS = %i[
    name
    model_id
    provider
    temperature
    instructions
    soul
    identity
    params
    thinking
  ].freeze

  class << self
    # @return [Hash] the configurable default values exposed by the API
    def defaults
      CONFIGURABLE_FIELDS.index_with { |field| default_for(field) }
    end

    # Resets the agent's configurable fields to their factory defaults.
    #
    # @param agent [Agent]
    # @return [Agent]
    def reset!(agent)
      agent.update!(defaults)
      agent
    end

    private

    # @param field [Symbol]
    # @return [Object]
    def default_for(field)
      VALUES.fetch(field).deep_dup
    end
  end
end
