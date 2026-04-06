# frozen_string_literal: true

# Nightly service that reviews staged memories and decides to promote, merge,
# or discard them. Also applies recency decay to promoted memories.
#
# This implements the "sleep cycle" pattern: memories extracted during
# conversations land as staged candidates and are only promoted to durable
# recall after this review pass.
class MemoryConsolidationService
  NEAR_DUPLICATE_THRESHOLD = 0.15
  DEFAULT_HALF_LIFE_DAYS = 30
  ACCESS_BUMP_THRESHOLD = 5
  IMPORTANCE_MIN = 1
  IMPORTANCE_MAX = 10

  # @param workspace [Workspace]
  def initialize(workspace:)
    @workspace = workspace
  end

  # Runs the full consolidation pass: promote staged, then decay promoted.
  #
  # @return [Hash] summary of actions taken
  def call
    stats = { promoted: 0, discarded: 0, superseded: 0, decayed: 0, bumped: 0 }

    staged = @workspace.memory_entries.active.staged.includes(:agent).to_a
    promoted_scope = @workspace.memory_entries.active.promoted

    staged.each do |candidate|
      action = evaluate_candidate(candidate, promoted_scope)
      case action[:decision]
      when :promote
        promote!(candidate)
        stats[:promoted] += 1
      when :discard_duplicate
        discard!(candidate, reason: "Near-duplicate of memory #{action[:existing_id]}")
        bump_importance!(action[:existing_entry]) if action[:existing_entry]
        stats[:discarded] += 1
      when :supersede
        supersede!(candidate, action[:existing_entry])
        stats[:superseded] += 1
      end
    end

    stats[:bumped] = bump_high_access_memories(promoted_scope)
    stats[:decayed] = apply_recency_decay(promoted_scope)

    stats
  end

  private

  # @param candidate [MemoryEntry]
  # @param promoted_scope [ActiveRecord::Relation]
  # @return [Hash]
  def evaluate_candidate(candidate, promoted_scope)
    return { decision: :promote } unless candidate.embedding.present?

    similar = promoted_scope
                .where(agent_id: candidate.agent_id)
                .embedded
                .nearest_neighbors(:embedding, candidate.embedding, distance: "cosine")
                .limit(3)
                .to_a

    return { decision: :promote } if similar.empty?

    closest = similar.first
    distance = closest.neighbor_distance

    if distance < NEAR_DUPLICATE_THRESHOLD
      if closest.category == candidate.category
        { decision: :discard_duplicate, existing_id: closest.id, existing_entry: closest }
      else
        { decision: :promote }
      end
    elsif distance < 0.3 && closest.category == candidate.category
      # Same topic, different content — newer supersedes older
      { decision: :supersede, existing_entry: closest }
    else
      { decision: :promote }
    end
  rescue StandardError => e
    Rails.logger.warn("[MemoryConsolidation] Evaluation failed for #{candidate.id}: #{e.message}")
    { decision: :promote }
  end

  # @param entry [MemoryEntry]
  # @return [void]
  def promote!(entry)
    entry.update_columns(staged: false, promoted_at: Time.current)
  end

  # @param entry [MemoryEntry]
  # @param reason [String]
  # @return [void]
  def discard!(entry, reason:)
    entry.update!(active: false)
    MemoryEntryVersion.record!(
      memory_entry: entry,
      action: "deactivated",
      reason: reason
    )
  end

  # @param newer [MemoryEntry]
  # @param older [MemoryEntry]
  # @return [void]
  def supersede!(newer, older)
    older.update!(active: false)
    MemoryEntryVersion.record!(
      memory_entry: older,
      action: "deactivated",
      reason: "Superseded by memory #{newer.id}"
    )
    promote!(newer)
  end

  # @param entry [MemoryEntry]
  # @return [void]
  def bump_importance!(entry)
    return if entry.importance >= IMPORTANCE_MAX

    entry.update_columns(importance: [ entry.importance + 1, IMPORTANCE_MAX ].min)
  end

  # Bumps importance for promoted memories with high access counts.
  #
  # @param scope [ActiveRecord::Relation]
  # @return [Integer] number of entries bumped
  def bump_high_access_memories(scope)
    scope.where("access_count >= ?", ACCESS_BUMP_THRESHOLD)
         .where("importance < ?", IMPORTANCE_MAX)
         .update_all("importance = LEAST(importance + 1, #{IMPORTANCE_MAX})")
  end

  # Applies recency decay: reduces importance of memories not accessed recently.
  #
  # @param scope [ActiveRecord::Relation]
  # @return [Integer] number of entries decayed
  def apply_recency_decay(scope)
    half_life = default_half_life_days
    cutoff = half_life.days.ago

    scope.where("importance > ?", IMPORTANCE_MIN)
         .where("last_accessed_at IS NULL OR last_accessed_at < ?", cutoff)
         .where("last_decay_at IS NULL OR last_decay_at < ?", cutoff)
         .update_all(
           [
             "importance = GREATEST(importance - 1, ?), last_decay_at = ?",
             IMPORTANCE_MIN, Time.current
           ]
         )
  end

  # @return [Integer]
  def default_half_life_days
    DEFAULT_HALF_LIFE_DAYS
  end
end
