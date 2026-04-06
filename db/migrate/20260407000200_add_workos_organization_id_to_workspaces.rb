# frozen_string_literal: true

# Maps WorkOS Organizations to DailyWerk Workspaces for enterprise SSO/SCIM.
# Nullable — personal workspaces without a WorkOS org continue to work.
class AddWorkosOrganizationIdToWorkspaces < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :workspaces, :workos_organization_id, :string, if_not_exists: true
    add_index  :workspaces, :workos_organization_id, unique: true,
               where: "workos_organization_id IS NOT NULL",
               algorithm: :concurrently, if_not_exists: true
  end
end
