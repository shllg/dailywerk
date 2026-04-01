# frozen_string_literal: true

# Combines semantic and full-text ranking for vault search.
class VaultSearchService
  MAX_QUERY_LENGTH = 1_000
  RRF_K = 60

  # @param vault [Vault]
  def initialize(vault:)
    @vault = vault
  end

  # @param query [String]
  # @param limit [Integer]
  # @return [Array<VaultChunk>]
  def search(query, limit: 5)
    normalized_query = query.to_s.strip
    raise ArgumentError, "query cannot be blank" if normalized_query.blank?
    raise ArgumentError, "query is too long" if normalized_query.length > MAX_QUERY_LENGTH

    embedding = RubyLLM.embed(
      normalized_query,
      dimensions: VaultChunk::EMBEDDING_DIMENSIONS
    ).vectors
    semantic_results = @vault.vault_chunks
                             .embedded
                             .nearest_neighbors(:embedding, embedding, distance: "cosine")
                             .limit(limit * 3)
    fulltext_results = fulltext_scope(normalized_query).limit(limit * 3)

    rrf_scores = Hash.new(0.0)
    semantic_results.each_with_index { |chunk, index| rrf_scores[chunk.id] += 1.0 / (RRF_K + index) }
    fulltext_results.each_with_index { |chunk, index| rrf_scores[chunk.id] += 1.0 / (RRF_K + index) }

    ordered_ids = rrf_scores.sort_by { |_, score| -score }.first(limit).map(&:first)
    @vault.vault_chunks.where(id: ordered_ids)
          .includes(:vault_file)
          .index_by(&:id)
          .values_at(*ordered_ids)
          .compact
  end

  private

  # @param query [String]
  # @return [ActiveRecord::Relation]
  def fulltext_scope(query)
    quoted_tsquery = ActiveRecord::Base.send(
      :sanitize_sql_array,
      [ "plainto_tsquery('english', ?)", query ]
    )

    @vault.vault_chunks
          .where("vault_chunks.tsv @@ plainto_tsquery('english', ?)", query)
          .order(Arel.sql("ts_rank(vault_chunks.tsv, #{quoted_tsquery}) DESC"))
  end
end
