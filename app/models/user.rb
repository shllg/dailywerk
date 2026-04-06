# frozen_string_literal: true

# Stores a person's identity and workspace memberships.
class User < ApplicationRecord
  has_many :user_sessions, dependent: :destroy, inverse_of: :user
  has_many :user_profiles, dependent: :destroy, inverse_of: :user
  has_many :workspace_memberships, dependent: :destroy, inverse_of: :user
  has_many :workspaces, through: :workspace_memberships
  has_many :owned_workspaces,
           class_name: "Workspace",
           foreign_key: :owner_id,
           dependent: :destroy,
           inverse_of: :owner

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email,
            presence: true,
            uniqueness: true,
            format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :status,
            presence: true,
            inclusion: { in: %w[pending active suspended cancelled] }
  validate :workos_id_immutable, on: :update

  scope :active, -> { where(status: "active") }

  # TODO: [WorkOS] Replace this with explicit workspace selection once
  # multi-workspace UI and session state exist.
  #
  # @return [Workspace, nil] the first workspace the user belongs to
  def default_workspace
    workspaces.order("workspace_memberships.created_at ASC").first
  end

  private

  # Prevents changing workos_id once it has been set.
  def workos_id_immutable
    if workos_id_changed? && workos_id_was.present?
      errors.add(:workos_id, "cannot be changed once set")
    end
  end
end
