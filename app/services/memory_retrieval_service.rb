# frozen_string_literal: true

# Selects relevant long-term memories and archived summaries for runtime prompts.
class MemoryRetrievalService
  MEMORY_BUDGET_RATIO = 0.10
  ARCHIVE_BUDGET_RATIO = 0.06
  MAX_QUERY_LENGTH = 2_000
  RRF_K = 60

  # @param session [Session]
  def initialize(session:)
    @session = session
    @workspace = session.workspace
    @agent = session.agent
  end

  # Builds a prompt-ready memory payload.
  #
  # @return [Hash]
  def build_context
    {
      memories: select_memories,
      archives: select_archives
    }
  end

  private

  # @return [Array<MemoryEntry>]
  def select_memories
    budget = ((@session.context_window_size * MEMORY_BUDGET_RATIO) / 4.0).ceil
    query = retrieval_query
    scope = scoped_memories.active.promoted
    candidates = query.present? ? rank_candidates(scope, query) : scope.order(importance: :desc, updated_at: :desc).limit(12).to_a

    keep_with_budget(candidates, budget) do |entry|
      estimate_tokens(entry.content)
    end.tap do |selected|
      mark_accessed(selected)
    end
  end

  # @return [Array<ConversationArchive>]
  def select_archives
    query = retrieval_query
    return [] if query.blank?

    archives = archived_scope
    return [] if archives.none?

    embedding = embed_query(query)
    return [] unless embedding

    budget = ((@session.context_window_size * ARCHIVE_BUDGET_RATIO) / 4.0).ceil
    candidates = archives.embedded.nearest_neighbors(:embedding, embedding, distance: "cosine").limit(6).to_a

    keep_with_budget(candidates, budget) do |archive|
      estimate_tokens(archive.summary)
    end
  rescue StandardError => e
    Rails.logger.error("[MemoryRetrieval] Archive selection failed for session #{@session.id}: #{e.message}")
    []
  end

  # @param scope [ActiveRecord::Relation]
  # @param query [String]
  # @return [Array<MemoryEntry>]
  def rank_candidates(scope, query)
    semantic_results = []
    embedding = embed_query(query)
    if embedding && scope.embedded.exists?
      semantic_results = scope.embedded.nearest_neighbors(:embedding, embedding, distance: "cosine").limit(12).to_a
    end

    lexical_results = lexical_candidates(scope, query)

    scores = Hash.new(0.0)
    semantic_results.each_with_index { |entry, index| scores[entry.id] += 1.0 / (RRF_K + index) }
    lexical_results.each_with_index { |entry, index| scores[entry.id] += 1.0 / (RRF_K + index) }

    scope.where(id: scores.keys)
         .to_a
         .sort_by do |entry|
           recency_bonus = entry.updated_at ? entry.updated_at.to_i / 1.day : 0
           -(scores[entry.id] + (entry.importance.to_f / 10.0) + (recency_bonus / 10_000.0))
         end
  end

  # @param scope [ActiveRecord::Relation]
  # @param query [String]
  # @return [Array<MemoryEntry>]
  def lexical_candidates(scope, query)
    keywords = query.to_s.downcase.scan(/[[:alnum:]]{3,}/).uniq.first(6)
    return scope.order(importance: :desc, updated_at: :desc).limit(12).to_a if keywords.empty?

    conditions = keywords.map { "memory_entries.content ILIKE ?" }.join(" OR ")
    values = keywords.map { |keyword| "%#{ActiveRecord::Base.sanitize_sql_like(keyword)}%" }

    scope.where(conditions, *values)
         .order(importance: :desc, updated_at: :desc)
         .limit(12)
         .to_a
  end

  # @param records [Array<Object>]
  # @param budget [Integer]
  # @yieldparam record [Object]
  # @return [Array<Object>]
  def keep_with_budget(records, budget)
    remaining = budget

    records.each_with_object([]) do |record, kept|
      estimated = yield(record)
      break if kept.any? && remaining - estimated < 0

      kept << record
      remaining -= estimated
    end
  end

  # @param entries [Array<MemoryEntry>]
  # @return [void]
  def mark_accessed(entries)
    return if entries.empty?

    MemoryEntry.where(id: entries.map(&:id)).update_all(
      [ "access_count = access_count + 1, last_accessed_at = ?", Time.current ]
    )
  end

  # @return [String]
  def retrieval_query
    @retrieval_query ||= begin
      content = @session.context_messages
                        .where(role: %w[user assistant])
                        .order(created_at: :desc)
                        .limit(4)
                        .reverse
                        .map(&:content_for_context)
                        .join("\n")
                        .strip
      content.first(MAX_QUERY_LENGTH)
    end
  end

  # @param text [String]
  # @return [Array<Float>, nil]
  def embed_query(text)
    return nil if text.blank?

    vector = RubyLLM.embed(text, dimensions: MemoryEntry::EMBEDDING_DIMENSIONS).vectors
    vector = vector.first if vector.is_a?(Array) && vector.first.is_a?(Array)
    vector
  end

  # @param text [String]
  # @return [Integer]
  def estimate_tokens(text)
    [ (text.to_s.length / 4.0).ceil, 1 ].max
  end

  # @return [ActiveRecord::Relation]
  def scoped_memories
    case @agent.memory_isolation
    when "isolated"
      @workspace.memory_entries.where(agent: @agent)
    else
      @workspace.memory_entries.where(agent_id: [ nil, @agent.id ])
    end
  end

  # @return [ActiveRecord::Relation]
  def archived_scope
    base = @workspace.conversation_archives.where.not(session_id: @session.id)

    case @agent.memory_isolation
    when "shared", "read_shared"
      base
    else
      base.where(agent: @agent)
    end
  end
end
