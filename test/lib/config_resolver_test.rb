# frozen_string_literal: true

require "test_helper"

class ConfigResolverTest < ActiveSupport::TestCase
  class FakeCredentials
    def initialize(data = {})
      @data = data
    end

    def dig(*keys)
      keys.reduce(@data) { |memo, key| memo&.dig(key.to_s) || memo&.dig(key.to_sym) }
    end
  end

  setup do
    @credentials = FakeCredentials.new(
      workos: { api_key: "cred-key", client_id: "cred-client" },
      openai: { api_key: "openai-cred" },
      numbers: { count: "42", flag: "true" }
    )
    @resolver = ConfigResolver.new(credentials: @credentials)
  end

  # -- precedence tests --

  test "resolve: ENV wins over credentials" do
    with_env("TEST_KEY" => "env-value") do
      creds = FakeCredentials.new(test: { key: "cred-value" })
      resolver = ConfigResolver.new(credentials: creds)
      result = resolver.resolve(:test, :key, env: "TEST_KEY")

      assert_equal "env-value", result
    end
  end

  test "resolve: credentials win over default" do
    result = @resolver.resolve(:workos, :api_key, env: "MISSING_ENV_VAR", default: "default-key")

    assert_equal "cred-key", result
  end

  test "resolve: default used when ENV and credentials missing in local env" do
    with_rails_env("development") do
      result = @resolver.resolve(:missing, :path, env: "MISSING_VAR", default: "fallback")

      assert_equal "fallback", result
    end
  end

  test "resolve: raises KeyError when missing in production with no default" do
    with_rails_env("production") do
      assert_raises(KeyError) do
        @resolver.resolve(:missing, :path, env: "MISSING_VAR")
      end
    end
  end

  test "resolve: force_default works even in production" do
    with_rails_env("production") do
      result = @resolver.resolve(:missing, :path, env: "MISSING_VAR", default: "forced", force_default: true)

      assert_equal "forced", result
    end
  end

  # -- type coercion tests --

  test "resolve: string type returns raw value" do
    result = @resolver.resolve(:workos, :api_key, type: :string)

    assert_equal "cred-key", result
  end

  test "resolve: integer type coerces string to integer" do
    result = @resolver.resolve(:numbers, :count, type: :integer)

    assert_equal 42, result
  end

  test "resolve: boolean type coerces string true to true" do
    result = @resolver.resolve(:numbers, :flag, type: :boolean)

    assert result
  end

  test "resolve: boolean type coerces from ENV" do
    with_env("BOOL_FLAG" => "false") do
      result = @resolver.resolve(:missing, :path, env: "BOOL_FLAG", default: "true", type: :boolean)

      refute result
    end
  end

  # -- resolve? tests --

  test "resolve?: returns nil when missing" do
    result = @resolver.resolve?(:missing, :path, env: "MISSING_VAR")

    assert_nil result
  end

  test "resolve?: returns value when found" do
    result = @resolver.resolve?(:workos, :api_key)

    assert_equal "cred-key", result
  end

  # -- edge cases --

  test "resolve: empty string ENV treated as missing" do
    with_env("EMPTY_VAR" => "") do
      result = @resolver.resolve(:workos, :api_key, env: "EMPTY_VAR", default: "fallback")

      assert_equal "cred-key", result
    end
  end

  test "resolve: works with no credential keys (ENV only)" do
    with_env("ONLY_ENV" => "env-only") do
      result = @resolver.resolve(env: "ONLY_ENV", default: "fallback")

      assert_equal "env-only", result
    end
  end

  test "resolve: missing ENV key skips to credentials" do
    result = @resolver.resolve(:workos, :api_key, env: nil)

    assert_equal "cred-key", result
  end

  test "resolve: non-string values are not coerced" do
    creds = FakeCredentials.new(nested: { count: 123, active: true })
    resolver = ConfigResolver.new(credentials: creds)

    assert_equal 123, resolver.resolve(:nested, :count, type: :integer)
    assert resolver.resolve(:nested, :active, type: :boolean)
  end

  private

  def with_env(overrides)
    previous = {}
    overrides.each do |key, value|
      previous[key] = ENV[key]
      ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  def with_rails_env(env)
    original = Rails.env
    Rails.env = env
    yield
  ensure
    Rails.env = original
  end
end
