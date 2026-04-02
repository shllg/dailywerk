# frozen_string_literal: true

# Stores an audit snapshot for every explicit memory mutation.
class MemoryEntryVersion < ApplicationRecord
  include WorkspaceScoped

  ACTIONS = %w[created updated deactivated reactivated].freeze

  belongs_to :memory_entry, inverse_of: :versions
  belongs_to :session, optional: true
  belongs_to :editor_user, class_name: "User", optional: true
  belongs_to :editor_agent, class_name: "Agent", optional: true

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :snapshot, presence: true
  validate :memory_entry_matches_workspace

  # Captures the current entry state as a version row.
  #
  # @param memory_entry [MemoryEntry]
  # @param action [String]
  # @param reason [String, nil]
  # @param session [Session, nil]
  # @param editor_user [User, nil]
  # @param editor_agent [Agent, nil]
  # @return [MemoryEntryVersion]
  def self.record!(memory_entry:, action:, reason: nil, session: nil, editor_user: nil, editor_agent: nil)
    create!(
      memory_entry:,
      workspace: memory_entry.workspace,
      session: session || memory_entry.session,
      editor_user:,
      editor_agent:,
      action:,
      reason:,
      snapshot: snapshot_for(memory_entry)
    )
  end

  # @param memory_entry [MemoryEntry]
  # @return [Hash]
  def self.snapshot_for(memory_entry)
    {
      "id" => memory_entry.id,
      "agent_id" => memory_entry.agent_id,
      "session_id" => memory_entry.session_id,
      "source_message_id" => memory_entry.source_message_id,
      "category" => memory_entry.category,
      "content" => memory_entry.content,
      "source" => memory_entry.source,
      "importance" => memory_entry.importance,
      "confidence" => memory_entry.confidence.to_f,
      "active" => memory_entry.active,
      "fingerprint" => memory_entry.fingerprint,
      "expires_at" => memory_entry.expires_at&.iso8601,
      "metadata" => memory_entry.metadata || {}
    }
  end

  private

  # @return [void]
  def memory_entry_matches_workspace
    return if memory_entry.blank? || workspace.blank?
    return if memory_entry.workspace_id == workspace_id

    errors.add(:memory_entry, "must belong to the current workspace")
  end
end
