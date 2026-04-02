# frozen_string_literal: true

# Restricts sensitive endpoints to workspace owners and admins.
module RequireWorkspaceAdmin
  extend ActiveSupport::Concern

  included do
    before_action :require_workspace_admin!
  end

  private

  # @return [void]
  def require_workspace_admin!
    membership = current_workspace&.workspace_memberships&.find_by(user_id: current_user&.id)
    return if membership&.role.in?(%w[owner admin])

    render json: { error: "Forbidden" }, status: :forbidden
  end
end
