ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    def create_user_with_workspace(
      email: "sascha-#{SecureRandom.hex(4)}@dailywerk.com",
      name: "Sascha",
      workspace_name: "Personal"
    )
      user = User.create!(email:, name:, status: "active")
      workspace = Workspace.create!(name: workspace_name, owner: user)
      WorkspaceMembership.create!(workspace:, user:, role: "owner")

      [ user, workspace ]
    end

    def with_current_workspace(workspace, user: workspace.owner)
      previous_user = Current.user
      previous_workspace = Current.workspace
      Current.user = user
      Current.workspace = workspace
      yield
    ensure
      Current.user = previous_user
      Current.workspace = previous_workspace
    end

    def api_auth_headers(user:, workspace:)
      token = Rails.application.message_verifier(:api_session).generate(
        { user_id: user.id, workspace_id: workspace.id },
        purpose: :api_session,
        expires_in: 12.hours
      )

      { "Authorization" => "Bearer #{token}" }
    end
  end
end
