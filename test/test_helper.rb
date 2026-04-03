ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    parallel_workers = ENV["PARALLEL_WORKERS"].presence
    parallel_threshold = ENV["PARALLELIZE_THRESHOLD"].presence

    # Run tests in parallel with a tunable threshold so opt-in integration
    # suites can force parallel execution without changing the default suite.
    parallelize(
      workers: parallel_workers ? parallel_workers.to_i : :number_of_processors,
      threshold: parallel_threshold ? parallel_threshold.to_i : 50
    )

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

    def with_env(overrides)
      previous_values = overrides.to_h do |key, _value|
        [ key, ENV.key?(key) ? ENV[key] : :__missing__ ]
      end

      overrides.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end

      yield
    ensure
      previous_values.each do |key, value|
        value == :__missing__ ? ENV.delete(key) : ENV[key] = value
      end
    end

    def with_openai_api_key(value: "test-openai-key")
      original_openai_api_key = RubyLLM.config.openai_api_key
      RubyLLM.config.openai_api_key = value

      yield
    ensure
      RubyLLM.config.openai_api_key = original_openai_api_key
    end

    def with_stubbed_ruby_llm_embed(value: 0.1, default_dimensions: 1536)
      original_embed = RubyLLM.method(:embed)

      RubyLLM.define_singleton_method(:embed) do |*_args, **kwargs|
        dimensions = kwargs[:dimensions] || default_dimensions
        Struct.new(:vectors).new(Array.new(dimensions, value))
      end

      yield
    ensure
      RubyLLM.define_singleton_method(:embed, original_embed)
    end
  end
end
