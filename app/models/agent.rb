# frozen_string_literal: true

# Stores the configuration for a workspace-scoped chat agent.
class Agent < ApplicationRecord
  include WorkspaceScoped

  has_many :sessions, dependent: :destroy, inverse_of: :agent

  validates :slug, presence: true, uniqueness: { scope: :workspace_id }
  validates :name, presence: true
  validates :model_id, presence: true

  scope :active, -> { where(active: true) }

  # @return [String] the system instructions passed to the LLM
  def resolved_instructions
    instructions.to_s
  end
end
