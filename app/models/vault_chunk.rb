# frozen_string_literal: true

# Stores one searchable chunk of markdown content from a vault file.
class VaultChunk < ApplicationRecord
  include WorkspaceScoped

  EMBEDDING_DIMENSIONS = 1536

  has_neighbors :embedding

  belongs_to :vault_file, inverse_of: :vault_chunks

  validates :file_path, presence: true
  validates :chunk_idx, presence: true
  validates :chunk_idx, uniqueness: { scope: :vault_file_id }
  validates :content, presence: true
  validate :vault_file_matches_workspace

  scope :embedded, -> { where.not(embedding: nil) }

  private

  # @return [void]
  def vault_file_matches_workspace
    return if vault_file.blank? || workspace.blank?
    return if vault_file.workspace_id == workspace_id

    errors.add(:vault_file, "must belong to the current workspace")
  end
end
