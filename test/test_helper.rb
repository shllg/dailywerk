ENV["RAILS_ENV"] ||= "test"

if ENV["COVERAGE"] == "1"
  require "simplecov"

  SimpleCov.command_name "rails-tests"
  SimpleCov.start "rails" do
    minimum = ENV.fetch("COVERAGE_MINIMUM", "0").to_f
    minimum_coverage line: minimum if minimum.positive?
  end
end

require_relative "../config/environment"
require "rails/test_help"
require "openssl"
require "jwt"

module ActiveSupport
  class TestCase
    # Coverage runs use a single worker so SimpleCov emits one stable result.
    parallel_workers = ENV["COVERAGE"] == "1" ? "1" : ENV["PARALLEL_WORKERS"].presence
    parallel_threshold = ENV["PARALLELIZE_THRESHOLD"].presence

    # Run tests in parallel with a tunable threshold so opt-in integration
    # suites can force parallel execution without changing the default suite.
    parallelize(
      workers: parallel_workers ? parallel_workers.to_i : :number_of_processors,
      threshold: parallel_threshold ? parallel_threshold.to_i : 50
    )

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Ensure vault paths use tmp directory for tests (override ENV setting)
    setup do
      @original_vault_local_base = Rails.configuration.x.vault_local_base
      Rails.configuration.x.vault_local_base = Rails.root.join("tmp/workspaces").to_s
    end

    teardown do
      Rails.configuration.x.vault_local_base = @original_vault_local_base if @original_vault_local_base
    end

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

    def silence_expected_logs(level: Logger::FATAL)
      return yield unless Rails.logger.respond_to?(:silence)

      Rails.logger.silence(level) do
        yield
      end
    end

    # Test RSA keypair for WorkOS JWT verification tests.
    TEST_JWKS_KEYPAIR = OpenSSL::PKey::RSA.generate(2048)
    TEST_JWKS_KID = "test-jwks-kid"

    # Returns Authorization headers with a WorkOS-style JWT for testing.
    #
    # @param user [User] must have a workos_id set
    # @param workspace [Workspace]
    # @return [Hash]
    def workos_auth_headers(user:, workspace:)
      payload = {
        "sub" => user.workos_id,
        "iss" => "https://api.workos.com/user_management/client_test_123",
        "iat" => Time.current.to_i,
        "exp" => 1.hour.from_now.to_i,
        "org_id" => workspace.workos_organization_id
      }

      token = JWT.encode(payload, TEST_JWKS_KEYPAIR, "RS256", { kid: TEST_JWKS_KID })
      { "Authorization" => "Bearer #{token}" }
    end

    # Sets up the JWKS L1 cache with the test keypair so WorkOS JWT
    # verification works without network calls.
    #
    # @return [void]
    def setup_test_jwks_cache
      WorkosJwksService::KEYS[TEST_JWKS_KID] = TEST_JWKS_KEYPAIR.public_key
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
