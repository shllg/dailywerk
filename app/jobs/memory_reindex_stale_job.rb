# frozen_string_literal: true

# Re-enqueues embeddings for memory records that are missing vectors.
class MemoryReindexStaleJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    each_workspace do |_workspace|
      MemoryEntry.where(embedding: nil).find_each do |entry|
        GenerateEmbeddingJob.perform_later("MemoryEntry", entry.id, workspace_id: entry.workspace_id)
      end

      ConversationArchive.where(embedding: nil).find_each do |archive|
        GenerateEmbeddingJob.perform_later(
          "ConversationArchive",
          archive.id,
          workspace_id: archive.workspace_id
        )
      end
    end
  end
end
