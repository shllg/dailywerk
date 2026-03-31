# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

user = User.find_or_create_by!(email: "sascha@dailywerk.com") do |record|
  record.name = "Sascha"
  record.status = "active"
end

unless user.workspaces.exists?
  workspace = Workspace.create!(name: "Personal", owner: user)
  WorkspaceMembership.create!(workspace:, user:, role: "owner")
end

Workspace.find_each do |workspace|
  Current.user = workspace.owner
  Current.workspace = workspace

  workspace.agents.find_or_create_by!(slug: AgentDefaults::VALUES[:slug]) do |agent|
    AgentDefaults::VALUES.except(:slug).each do |field, value|
      agent.public_send(:"#{field}=", value.deep_dup)
    end

    agent.is_default = true
  end
end

Current.reset_context!
