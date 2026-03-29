# frozen_string_literal: true

# Connects a user to a workspace with a role.
class WorkspaceMembership < ApplicationRecord
  belongs_to :workspace
  belongs_to :user

  validates :role,
            presence: true,
            inclusion: { in: %w[owner admin member viewer] }
  validates :user_id, uniqueness: { scope: :workspace_id }

  # TODO: [Abilities] Keep all abilities implicitly granted for now.
  # When granular permissions ship, persist them in `abilities`.
end
