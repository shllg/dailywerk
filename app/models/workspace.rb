# frozen_string_literal: true

# Groups the data a user or team works inside.
class Workspace < ApplicationRecord
  belongs_to :owner, class_name: "User", inverse_of: :owned_workspaces

  has_many :agents, dependent: :destroy, inverse_of: :workspace
  has_many :conversation_archives, dependent: :destroy, inverse_of: :workspace
  has_many :memory_entries, dependent: :destroy, inverse_of: :workspace
  has_many :memory_entry_versions, dependent: :destroy, inverse_of: :workspace
  has_many :sessions, dependent: :destroy, inverse_of: :workspace
  has_many :user_profiles, dependent: :destroy, inverse_of: :workspace
  has_many :vaults, dependent: :destroy, inverse_of: :workspace
  has_many :workspace_memberships, dependent: :destroy, inverse_of: :workspace
  has_many :users, through: :workspace_memberships

  validates :name, presence: true

  before_destroy :disable_workspace_scoping_for_destroy, prepend: true
  after_destroy :restore_workspace_scoping_after_destroy
  after_rollback :restore_workspace_scoping_after_destroy, on: :destroy

  private

  # Disables workspace scoping early enough for dependent destroy callbacks.
  #
  # @return [void]
  def disable_workspace_scoping_for_destroy
    @previous_destroy_skip_workspace_scoping = Current.skip_workspace_scoping
    Current.skip_workspace_scoping = true
  end

  # Restores the prior workspace scoping flag after destroy completes or rolls back.
  #
  # @return [void]
  def restore_workspace_scoping_after_destroy
    return unless instance_variable_defined?(:@previous_destroy_skip_workspace_scoping)

    Current.skip_workspace_scoping = @previous_destroy_skip_workspace_scoping
    remove_instance_variable(:@previous_destroy_skip_workspace_scoping)
  end
end
