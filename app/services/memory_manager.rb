# frozen_string_literal: true

# Handles the creation, mutation, and audit history for structured memories.
class MemoryManager
  VISIBILITIES = %w[shared private].freeze
  # Internal parameter object for store/create/update flows.
  StoreRequest = Struct.new(
    :content,
    :category,
    :importance,
    :confidence,
    :visibility,
    :agent,
    :source,
    :metadata,
    :reason,
    :source_message,
    :expires_at,
    keyword_init: true
  ) do
    def normalized_content
      content.to_s.squish
    end

    def clamped_importance
      importance.to_i.clamp(1, 10)
    end

    def clamped_confidence
      confidence.to_f.clamp(0.0, 1.0)
    end
  end

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
    request = StoreRequest.new(
      content:,
      category:,
      importance:,
      confidence:,
      visibility:,
      agent:,
      source:,
      metadata:,
      reason:,
      source_message:,
      expires_at:
    )
    raise ArgumentError, "content cannot be blank" if request.normalized_content.blank?

    target_agent = resolve_agent_scope(visibility: request.visibility, agent: request.agent)
    fingerprint = MemoryEntry.fingerprint_for(
      category: request.category,
      content: request.normalized_content
    )
    entry = @workspace.memory_entries.active.find_by(agent: target_agent, fingerprint:)

    if entry
      update_existing_entry(entry, request:)
    else
      create_entry(request:, agent: target_agent)
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
    updates[:metadata] = (entry.metadata || {}).deep_merge(normalize_metadata(updates[:metadata])) if updates[:metadata]

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
  # @param request [StoreRequest]
  # @return [MemoryEntry]
  def update_existing_entry(entry, request:)
    merged_metadata = (entry.metadata || {}).deep_merge(normalize_metadata(request.metadata))
    entry.update!(
      content: request.normalized_content,
      category: request.category,
      importance: request.clamped_importance,
      confidence: request.clamped_confidence,
      source: request.source,
      metadata: merged_metadata,
      session: @session || entry.session,
      source_message: request.source_message || entry.source_message,
      expires_at: request.expires_at || entry.expires_at,
      active: true
    )
    MemoryEntryVersion.record!(
      memory_entry: entry,
      action: "updated",
      reason: request.reason.presence || "Existing memory refreshed",
      session: @session,
      editor_user: @actor_user,
      editor_agent: @actor_agent
    )
    enqueue_embedding(entry)
    entry
  end

  # @param request [StoreRequest]
  # @param agent [Agent, nil]
  # @return [MemoryEntry]
  def create_entry(request:, agent:)
    entry = @workspace.memory_entries.create!(
      agent:,
      session: @session,
      source_message: request.source_message,
      category: request.category,
      content: request.normalized_content,
      source: request.source,
      importance: request.clamped_importance,
      confidence: request.clamped_confidence,
      metadata: normalize_metadata(request.metadata),
      expires_at: request.expires_at
    )
    MemoryEntryVersion.record!(
      memory_entry: entry,
      action: "created",
      reason: request.reason,
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
      :source,
      :visibility
    )
  end

  # @param metadata [Hash, ActionController::Parameters, nil]
  # @return [Hash]
  def normalize_metadata(metadata)
    raw_metadata =
      case metadata
      when ActionController::Parameters
        metadata.to_h
      else
        metadata || {}
      end

    raw_metadata.deep_stringify_keys
  end
end
