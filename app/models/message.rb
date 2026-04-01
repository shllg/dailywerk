# frozen_string_literal: true

# Stores persisted chat messages for a workspace-scoped session.
class Message < ApplicationRecord
  include WorkspaceScoped

  acts_as_message chat: :session, tool_calls: :tool_calls, model_class: "RubyLLM::ModelRecord"

  scope :active, -> { where(compacted: false) }
  scope :for_context, -> { active.order(:created_at) }
  scope :compacted, -> { where(compacted: true) }

  # Returns the content that should be replayed back into model context.
  # Media-specific pipelines can store a short description in
  # `media_description`; the session runtime reuses that text instead of the
  # original payload when rebuilding context.
  #
  # @return [String]
  def content_for_context
    media_description.presence || content.to_s
  end

  validate :session_belongs_to_workspace

  private

  # Keeps the denormalized workspace_id aligned with the parent session.
  #
  # @return [void]
  def session_belongs_to_workspace
    return if session.blank? || workspace.blank?
    return if session.workspace_id == workspace_id

    errors.add(:session, "must belong to the current workspace")
  end
end
