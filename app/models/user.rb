# frozen_string_literal: true

# Stores a person's identity and workspace memberships.
class User < ApplicationRecord
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

  scope :active, -> { where(status: "active") }

  # TODO: [WorkOS] Replace this with explicit workspace selection once
  # multi-workspace UI and session state exist.
  #
  # @return [Workspace, nil] the first workspace the user belongs to
  def default_workspace
    workspaces.order("workspace_memberships.created_at ASC").first
  end
end
