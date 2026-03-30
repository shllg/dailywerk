# frozen_string_literal: true

# Stores persisted chat messages for a workspace-scoped session.
class Message < ApplicationRecord
  include WorkspaceScoped

  acts_as_message chat: :session, tool_calls: :tool_calls, model_class: "RubyLLM::ModelRecord"

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
