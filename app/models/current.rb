# frozen_string_literal: true

# Stores request-local auth and workspace context.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :workspace, :skip_workspace_scoping, :request_id

  # Clears the workspace when the current user changes.
  #
  # @param new_user [User, nil]
  # @return [void]
  def user=(new_user)
    previous_user = user
    super

    self.workspace = nil if previous_user != new_user
  end

  # @return [Boolean] true when workspace scoping is disabled for this request
  def skip_workspace_scoping?
    skip_workspace_scoping == true
  end

  # Runs a block without automatic workspace scopes.
  #
  # @yield Runs with workspace scoping disabled.
  # @return [Object] the block result
  def without_workspace_scoping
    previous_skip = skip_workspace_scoping
    self.skip_workspace_scoping = true
    yield
  ensure
    self.skip_workspace_scoping = previous_skip
  end

  # Resets all request-local values.
  #
  # @return [void]
  def reset_context!
    self.user = nil
    self.workspace = nil
    self.skip_workspace_scoping = nil
    self.request_id = nil
  end

  resets do
    reset_context!
  end
end
