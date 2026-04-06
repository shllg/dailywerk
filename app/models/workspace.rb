# frozen_string_literal: true

# Groups the data a user or team works inside.
class Workspace < ApplicationRecord
  belongs_to :owner, class_name: "User", inverse_of: :owned_workspaces

  has_many :agents, dependent: :destroy, inverse_of: :workspace
  has_many :conversation_archives, dependent: :destroy, inverse_of: :workspace
  has_many :memory_entries, dependent: :destroy, inverse_of: :workspace
  has_many :memory_entry_versions, dependent: :destroy, inverse_of: :workspace
  has_many :sessions, inverse_of: :workspace
  has_many :user_profiles, dependent: :destroy, inverse_of: :workspace
  has_many :messages, inverse_of: :workspace
  has_many :vaults, dependent: :destroy, inverse_of: :workspace
  has_many :workspace_memberships, dependent: :destroy, inverse_of: :workspace
  has_many :users, through: :workspace_memberships

  validates :name, presence: true
end
