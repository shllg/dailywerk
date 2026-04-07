# frozen_string_literal: true

# Adds automatic workspace ownership rules to a model.
module WorkspaceScoped
  extend ActiveSupport::Concern

  included do
    default_scope lambda {
      if Current.skip_workspace_scoping?
        all
      elsif Current.workspace
        where(workspace_id: Current.workspace.id)
      else
        none
      end
    }

    belongs_to :workspace

    validates :workspace, presence: true
    validate :workspace_matches_current_context, if: :should_validate_workspace_context?
    validate :workspace_unchanged, on: :update, if: :should_validate_workspace_context?

    before_validation :set_workspace_from_context, on: :create, prepend: true
    before_destroy :disable_workspace_scoping_for_destroy, prepend: true
    after_destroy :restore_workspace_scoping_after_destroy
    after_rollback :restore_workspace_scoping_after_destroy, on: :destroy
  end

  private

  # @return [Boolean] true when the current request should enforce workspace checks
  def should_validate_workspace_context?
    !Current.skip_workspace_scoping?
  end

  # Copies the current request workspace onto new records.
  #
  # @return [void]
  def set_workspace_from_context
    self.workspace ||= Current.workspace
  end

  # Rejects records that point at a different workspace.
  #
  # @return [void]
  def workspace_matches_current_context
    if Current.workspace.nil?
      errors.add(:workspace, "must be set through Current.workspace")
    elsif workspace != Current.workspace
      errors.add(:workspace, "must match Current.workspace")
    end
  end

  # Prevents moving a record to another workspace after it exists.
  #
  # @return [void]
  def workspace_unchanged
    return unless will_save_change_to_workspace_id?

    errors.add(:workspace, "cannot be changed")
  end

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
