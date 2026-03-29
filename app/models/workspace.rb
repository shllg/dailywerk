# frozen_string_literal: true

# Groups the data a user or team works inside.
class Workspace < ApplicationRecord
  belongs_to :owner, class_name: "User", inverse_of: :owned_workspaces

  has_many :workspace_memberships, dependent: :destroy, inverse_of: :workspace
  has_many :users, through: :workspace_memberships

  validates :name, presence: true
end
