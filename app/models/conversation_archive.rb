# frozen_string_literal: true

# Stores an archived session summary for later semantic recall and inspection.
class ConversationArchive < ApplicationRecord
  include WorkspaceScoped

  EMBEDDING_DIMENSIONS = 1536

  has_neighbors :embedding

  belongs_to :session
  belongs_to :agent

  validates :session_id, uniqueness: true
  validates :summary, presence: true
  validate :session_matches_workspace
  validate :agent_matches_workspace

  scope :embedded, -> { where.not(embedding: nil) }

  # @return [String]
  def embedding_source_text
    [ summary, *Array(key_facts) ].compact.join("\n")
  end

  private

  # @return [void]
  def session_matches_workspace
    return if session.blank? || workspace.blank?
    return if session.workspace_id == workspace_id

    errors.add(:session, "must belong to the current workspace")
  end

  # @return [void]
  def agent_matches_workspace
    return if agent.blank? || workspace.blank?
    return if agent.workspace_id == workspace_id

    errors.add(:agent, "must belong to the current workspace")
  end
end
