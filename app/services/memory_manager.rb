# frozen_string_literal: true

# Handles the creation, mutation, and audit history for structured memories.
class MemoryManager
  VISIBILITIES = %w[shared private].freeze

  # @param workspace [Workspace]
  # @param actor_user [User, nil]
  # @param actor_agent [Agent, nil]
  # @param session [Session, nil]
  def initialize(workspace:, actor_user: Current.user, actor_agent: nil, session: nil)
    @workspace = workspace
    @actor_user = actor_user
    @actor_agent = actor_agent
    @session = session
  end

  # Creates or updates a structured memory in the appropriate scope.
  #
  # @param content [String]
  # @param category [String]
  # @param importance [Integer]
  # @param confidence [Float, BigDecimal]
  # @param visibility [String, nil]
  # @param agent [Agent, nil]
  # @param source [String]
  # @param metadata [Hash]
  # @param reason [String, nil]
  # @param source_message [Message, nil]
  # @param expires_at [Time, nil]
  # @return [MemoryEntry]
  def store(
    content:,
    category:,
    importance: 5,
    confidence: 0.7,
    visibility: nil,
    agent: @actor_agent,
    source: "system",
    metadata: {},
    reason: nil,
    source_message: nil,
    expires_at: nil
  )
    normalized_content = content.to_s.squish
    raise ArgumentError, "content cannot be blank" if normalized_content.blank?

    target_agent = resolve_agent_scope(visibility:, agent:)
    fingerprint = MemoryEntry.fingerprint_for(category:, content: normalized_content)
    entry = @workspace.memory_entries.active.find_by(agent: target_agent, fingerprint:)

    if entry
      update_existing_entry(
        entry,
        normalized_content:,
        category:,
        importance:,
        confidence:,
        source:,
        metadata:,
        source_message:,
        expires_at:,
        reason:
      )
    else
      create_entry(
        content: normalized_content,
        category:,
        importance:,
        confidence:,
        agent: target_agent,
        source:,
        metadata:,
        source_message:,
        expires_at:,
        reason:
      )
    end
  end

  # Applies an explicit edit to a memory entry.
  #
  # @param entry [MemoryEntry]
  # @param attributes [Hash]
  # @param reason [String, nil]
  # @return [MemoryEntry]
  def update(entry:, attributes:, reason: nil)
    updates = permitted_updates(attributes)
    visibility = updates.delete(:visibility)
    agent = updates.delete(:agent)
    updates[:agent] = resolve_agent_scope(visibility:, agent:) if visibility.present? || attributes.key?(:agent)
    updates[:metadata] = (entry.metadata || {}).deep_merge((updates[:metadata] || {}).deep_stringify_keys) if updates[:metadata]

    entry.update!(updates)
    MemoryEntryVersion.record!(
      memory_entry: entry,
      action: "updated",
      reason:,
      session: @session,
      editor_user: @actor_user,
      editor_agent: @actor_agent
    )
    enqueue_embedding(entry)
    entry
  end

  # Marks a memory entry inactive while preserving its audit history.
  #
  # @param entry [MemoryEntry]
  # @param reason [String, nil]
  # @return [MemoryEntry]
  def deactivate(entry:, reason: nil)
    return entry unless entry.active?

    entry.update!(active: false)
    MemoryEntryVersion.record!(
      memory_entry: entry,
      action: "deactivated",
      reason:,
      session: @session,
      editor_user: @actor_user,
      editor_agent: @actor_agent
    )
    entry
  end

  # Re-enables a previously inactive memory entry.
  #
  # @param entry [MemoryEntry]
  # @param reason [String, nil]
  # @return [MemoryEntry]
  def reactivate(entry:, reason: nil)
    return entry if entry.active?

    entry.update!(active: true)
    MemoryEntryVersion.record!(
      memory_entry: entry,
      action: "reactivated",
      reason:,
      session: @session,
      editor_user: @actor_user,
      editor_agent: @actor_agent
    )
    enqueue_embedding(entry)
    entry
  end

  private

  # @param visibility [String, nil]
  # @param agent [Agent, nil]
  # @return [Agent, nil]
  def resolve_agent_scope(visibility:, agent:)
    normalized_visibility = visibility.to_s.presence
    if normalized_visibility.present?
      raise ArgumentError, "visibility must be shared or private" unless VISIBILITIES.include?(normalized_visibility)

      return nil if normalized_visibility == "shared"

      return agent || @actor_agent || raise(ArgumentError, "private memories require an agent")
    end

    return nil unless @actor_agent

    @actor_agent.memory_isolation == "shared" ? nil : @actor_agent
  end

  # @param entry [MemoryEntry]
  # @param normalized_content [String]
  # @param category [String]
  # @param importance [Integer]
  # @param confidence [Float, BigDecimal]
  # @param source [String]
  # @param metadata [Hash]
  # @param source_message [Message, nil]
  # @param expires_at [Time, nil]
  # @param reason [String, nil]
  # @return [MemoryEntry]
  def update_existing_entry(
    entry,
    normalized_content:,
    category:,
    importance:,
    confidence:,
    source:,
    metadata:,
    source_message:,
    expires_at:,
    reason:
  )
    merged_metadata = (entry.metadata || {}).deep_merge(metadata.deep_stringify_keys)
    entry.update!(
      content: normalized_content,
      category:,
      importance: [ entry.importance.to_i, importance.to_i ].max,
      confidence: [ entry.confidence.to_f, confidence.to_f ].max,
      source:,
      metadata: merged_metadata,
      session: @session || entry.session,
      source_message: source_message || entry.source_message,
      expires_at: expires_at || entry.expires_at,
      active: true
    )
    MemoryEntryVersion.record!(
      memory_entry: entry,
      action: "updated",
      reason: reason.presence || "Existing memory refreshed",
      session: @session,
      editor_user: @actor_user,
      editor_agent: @actor_agent
    )
    enqueue_embedding(entry)
    entry
  end

  # @param content [String]
  # @param category [String]
  # @param importance [Integer]
  # @param confidence [Float, BigDecimal]
  # @param agent [Agent, nil]
  # @param source [String]
  # @param metadata [Hash]
  # @param source_message [Message, nil]
  # @param expires_at [Time, nil]
  # @param reason [String, nil]
  # @return [MemoryEntry]
  def create_entry(
    content:,
    category:,
    importance:,
    confidence:,
    agent:,
    source:,
    metadata:,
    source_message:,
    expires_at:,
    reason:
  )
    entry = @workspace.memory_entries.create!(
      agent:,
      session: @session,
      source_message:,
      category:,
      content:,
      source:,
      importance: importance.to_i.clamp(1, 10),
      confidence: confidence.to_f.clamp(0.0, 1.0),
      metadata: metadata.deep_stringify_keys,
      expires_at:
    )
    MemoryEntryVersion.record!(
      memory_entry: entry,
      action: "created",
      reason:,
      session: @session,
      editor_user: @actor_user,
      editor_agent: @actor_agent
    )
    enqueue_embedding(entry)
    entry
  end

  # @param entry [MemoryEntry]
  # @return [void]
  def enqueue_embedding(entry)
    GenerateEmbeddingJob.perform_later("MemoryEntry", entry.id, workspace_id: @workspace.id)
  end

  # @param attributes [Hash]
  # @return [Hash]
  def permitted_updates(attributes)
    normalized = attributes.deep_symbolize_keys

    normalized.slice(
      :active,
      :agent,
      :category,
      :confidence,
      :content,
      :expires_at,
      :importance,
      :metadata,
      :source
    )
  end
end
