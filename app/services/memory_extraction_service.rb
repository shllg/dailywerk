# frozen_string_literal: true

# Extracts durable memories from conversational text into a structured schema.
class MemoryExtractionService
  MEMORY_SCHEMA = {
    type: "object",
    properties: {
      memories: {
        type: "array",
        items: {
          type: "object",
          properties: {
            content: { type: "string" },
            category: {
              type: "string",
              enum: MemoryEntry::CATEGORIES
            },
            importance: { type: "integer", minimum: 1, maximum: 10 },
            confidence: { type: "number", minimum: 0, maximum: 1 },
            visibility: { type: "string", enum: MemoryManager::VISIBILITIES }
          },
          required: %w[content category importance confidence visibility],
          additionalProperties: false
        }
      }
    },
    required: [ "memories" ],
    additionalProperties: false
  }.freeze
  DEFAULT_MODEL = "gpt-4o-mini"

  # @param session [Session]
  def initialize(session:)
    @session = session
    @agent = session.agent
  end

  # Extracts memory candidates from the given transcript text.
  #
  # @param transcript [String]
  # @return [Array<Hash>]
  def extract(transcript)
    normalized_transcript = transcript.to_s.strip
    return [] if normalized_transcript.blank?

    response = RubyLLM.chat(model: extraction_model)
                      .with_temperature(0.1)
                      .with_schema(MEMORY_SCHEMA)
                      .ask(extraction_prompt(normalized_transcript))

    Array(response.content["memories"]).filter_map do |memory|
      normalized = memory.deep_symbolize_keys
      content = normalized[:content].to_s.squish
      next if content.blank?

      {
        content:,
        category: normalized[:category].presence || "fact",
        importance: normalized[:importance].to_i.clamp(1, 10),
        confidence: normalized[:confidence].to_f.clamp(0.0, 1.0),
        visibility: normalized[:visibility].presence || default_visibility
      }
    end
  rescue StandardError => e
    Rails.logger.error("[MemoryExtraction] Failed for session #{@session.id}: #{e.message}")
    []
  end

  private

  # @return [String]
  def extraction_model
    normalized_params["compaction_model"].presence || @agent.model_id || DEFAULT_MODEL
  end

  # @return [String]
  def default_visibility
    @agent.memory_isolation == "shared" ? "shared" : "private"
  end

  # @param transcript [String]
  # @return [String]
  def extraction_prompt(transcript)
    <<~PROMPT
      Extract durable memories from this conversation fragment.

      Only return memories that should help the system remember the user over time:
      - stable preferences
      - recurring facts about the user, people, or projects
      - standing instructions or rules
      - important ongoing context that will matter in future sessions

      Do not store:
      - greetings
      - one-off scheduling details that already expired
      - speculative assumptions
      - facts that are already obvious from the current message only

      Choose visibility carefully:
      - "shared" for user-wide facts, preferences, or instructions that other agents should know
      - "private" for agent-specific working knowledge or specialist context

      Conversation:
      #{transcript}
    PROMPT
  end

  # @return [Hash]
  def normalized_params
    @normalized_params ||= @agent.params.is_a?(Hash) ? @agent.params.deep_stringify_keys : {}
  end
end
