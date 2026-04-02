# frozen_string_literal: true

# Exposes structured memory recall and maintenance to the active agent.
class MemoryTool < RubyLLM::Tool
  ACTIONS = %w[store recall list update forget].freeze
  PARAMETERS_SCHEMA = {
    type: "object",
    properties: {
      action: {
        type: "string",
        enum: ACTIONS,
        description: "One of: store, recall, list, update, forget"
      },
      content: {
        anyOf: [
          { type: "string" },
          { type: "null" }
        ],
        description: "Memory content to store or replace"
      },
      category: {
        anyOf: [
          { type: "string", enum: MemoryEntry::CATEGORIES },
          { type: "null" }
        ],
        description: "Memory category"
      },
      importance: {
        anyOf: [
          { type: "integer", minimum: 1, maximum: 10 },
          { type: "null" }
        ],
        description: "Importance score from 1 to 10"
      },
      confidence: {
        anyOf: [
          { type: "number", minimum: 0, maximum: 1 },
          { type: "null" }
        ],
        description: "Confidence score from 0.0 to 1.0"
      },
      query: {
        anyOf: [
          { type: "string" },
          { type: "null" }
        ],
        description: "Search query for recall"
      },
      memory_id: {
        anyOf: [
          { type: "string" },
          { type: "null" }
        ],
        description: "Memory UUID for update or forget"
      },
      visibility: {
        anyOf: [
          { type: "string", enum: MemoryManager::VISIBILITIES },
          { type: "null" }
        ],
        description: "shared or private"
      }
    },
    required: %w[action content category importance confidence query memory_id visibility],
    additionalProperties: false
  }.freeze

  description "Reads and maintains structured long-term memory for the current workspace"
  params PARAMETERS_SCHEMA
  with_params(function: { strict: true })

  # @param user [User, nil]
  # @param session [Session]
  def initialize(user:, session:)
    @user = user
    @session = session
    @workspace = Current.workspace || session.workspace
  end

  # @param action [String]
  # @param content [String, nil]
  # @param category [String, nil]
  # @param importance [Integer, nil]
  # @param confidence [Float, nil]
  # @param query [String, nil]
  # @param memory_id [String, nil]
  # @param visibility [String, nil]
  # @return [Hash, Array<Hash>]
  def execute(
    action:,
    content: nil,
    category: nil,
    importance: nil,
    confidence: nil,
    query: nil,
    memory_id: nil,
    visibility: nil
  )
    case action
    when "store"
      store_memory(content:, category:, importance:, confidence:, visibility:)
    when "recall"
      recall_memories(query)
    when "list"
      list_memories
    when "update"
      update_memory(memory_id:, content:, category:, importance:, confidence:, visibility:)
    when "forget"
      forget_memory(memory_id)
    else
      { error: "unsupported memory action" }
    end
  rescue ActiveRecord::RecordNotFound
    { error: "memory not found" }
  rescue ArgumentError => e
    { error: e.message }
  end

  private

  # @return [MemoryManager]
  def manager
    @manager ||= MemoryManager.new(
      workspace: @workspace,
      actor_user: @user,
      actor_agent: @session.agent,
      session: @session
    )
  end

  # @param content [String, nil]
  # @param category [String, nil]
  # @param importance [Integer, nil]
  # @param confidence [Float, nil]
  # @param visibility [String, nil]
  # @return [Hash]
  def store_memory(content:, category:, importance:, confidence:, visibility:)
    entry = manager.store(
      content: content.to_s,
      category: category.presence || "fact",
      importance: importance || 5,
      confidence: confidence || 0.7,
      visibility: visibility,
      source: "tool"
    )

    memory_payload(entry)
  end

  # @param query [String, nil]
  # @return [Array<Hash>]
  def recall_memories(query)
    raise ArgumentError, "query is required" if query.to_s.strip.blank?

    retrieval_service = MemoryRetrievalService.new(session: @session)
    retrieval_service.send(:rank_candidates, scoped_memories.active, query.to_s.strip).first(5).map do |entry|
      memory_payload(entry)
    end
  end

  # @return [Array<Hash>]
  def list_memories
    scoped_memories.active.order(importance: :desc, updated_at: :desc).limit(20).map do |entry|
      memory_payload(entry)
    end
  end

  # @param memory_id [String, nil]
  # @param content [String, nil]
  # @param category [String, nil]
  # @param importance [Integer, nil]
  # @param confidence [Float, nil]
  # @param visibility [String, nil]
  # @return [Hash]
  def update_memory(memory_id:, content:, category:, importance:, confidence:, visibility:)
    raise ArgumentError, "memory_id is required" if memory_id.blank?

    entry = scoped_memories.find(memory_id)
    manager.update(
      entry:,
      attributes: {
        content: content.presence || entry.content,
        category: category.presence || entry.category,
        importance: importance || entry.importance,
        confidence: confidence || entry.confidence,
        visibility:
      },
      reason: "MemoryTool update"
    )

    memory_payload(entry.reload)
  end

  # @param memory_id [String, nil]
  # @return [Hash]
  def forget_memory(memory_id)
    raise ArgumentError, "memory_id is required" if memory_id.blank?

    entry = scoped_memories.find(memory_id)
    manager.deactivate(entry:, reason: "Forgotten by MemoryTool")
    memory_payload(entry.reload)
  end

  # @return [ActiveRecord::Relation]
  def scoped_memories
    case @session.agent.memory_isolation
    when "isolated"
      @workspace.memory_entries.where(agent: @session.agent)
    else
      @workspace.memory_entries.where(agent_id: [ nil, @session.agent.id ])
    end
  end

  # @param entry [MemoryEntry]
  # @return [Hash]
  def memory_payload(entry)
    {
      id: entry.id,
      category: entry.category,
      content: entry.content,
      importance: entry.importance,
      confidence: entry.confidence.to_f.round(2),
      visibility: entry.scope_label,
      agent_id: entry.agent_id,
      active: entry.active
    }
  end
end
