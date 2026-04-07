# frozen_string_literal: true

# Re-enqueues stale indexing work for chunks and markdown files.
class VaultReindexStaleJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    each_workspace do |_workspace|
      VaultChunk.where(embedding: nil).find_each do |chunk|
        GenerateEmbeddingJob.perform_later("VaultChunk", chunk.id, workspace_id: chunk.workspace_id)
      end

      VaultFile.markdown.where(indexed_at: nil).find_each do |vault_file|
        VaultFileChangedJob.perform_later(
          vault_file.vault_id,
          vault_file.path,
          "modify",
          workspace_id: vault_file.workspace_id
        )
      end
    end
  end
end
