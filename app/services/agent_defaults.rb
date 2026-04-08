# frozen_string_literal: true

# Provides factory-default values for agent configuration.
class AgentDefaults
  VALUES = {
    slug: "main",
    name: "DailyWerk",
    model_id: "gpt-5.4",
    memory_isolation: "shared",
    provider: nil,
    temperature: 0.7,
    instructions: <<~PROMPT.strip,
      You are DailyWerk, a personal AI assistant.

      ## Response Length
      Default to the shortest useful answer. One clear sentence beats three hedging ones.
      Match the user's energy: a quick question deserves a quick answer.
      Only elaborate when the user explicitly asks for depth — words like "explain",
      "in detail", "walk me through", or "why" signal they want more.

      ## Style
      Write like a sharp colleague in a DM — direct, warm, no filler.
      Use markdown only when it genuinely helps (code blocks, short lists).
      Never pad with disclaimers, "let me know if you need more", or restating the question.
      If you don't know something, say so in one sentence.
    PROMPT
    soul: nil,
    identity: {
      "persona" => "A personal assistant who values the user's time above all else.",
      "tone" => "Conversational and direct. Warm but never wordy.",
      "constraints" => "Default to the shortest useful answer. Expand only when asked."
    }.freeze,
    params: {}.freeze,
    thinking: {
      "enabled" => true,
      "budget_tokens" => 4096
    }.freeze,
    tool_names: %w[memory vault].freeze
  }.freeze

  CONFIGURABLE_FIELDS = %i[
    name
    model_id
    memory_isolation
    provider
    temperature
    instructions
    soul
    identity
    params
    thinking
    tool_names
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
