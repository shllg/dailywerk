# frozen_string_literal: true

# Stores a synthesized profile for a user within a workspace.
#
# Built nightly by ProfileSynthesisJob from promoted memories and recent
# archives. Always injected into the agent's system prompt so the assistant
# knows who it is talking to without relying solely on query-time recall.
class UserProfile < ApplicationRecord
  include WorkspaceScoped

  belongs_to :user

  validates :user_id, uniqueness: { scope: :workspace_id }
end
