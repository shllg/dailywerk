# frozen_string_literal: true

require "test_helper"
require "openssl"
require "jwt"

# rubocop:disable Minitest/MultipleAssertions
class WorkosJwksServiceTest < ActiveSupport::TestCase
  TEST_KID = "test-kid-#{SecureRandom.hex(4)}"
  TEST_CLIENT_ID = "client_test_123"
  TEST_ISSUER = "https://api.workos.com/user_management/client_test_123"

  setup do
    @rsa_key = OpenSSL::PKey::RSA.generate(2048)
    @jwk = JWT::JWK.new(@rsa_key, kid: TEST_KID)

    # Clear L1 cache and rate-limit state between tests
    WorkosJwksService::KEYS.each_key { |k| WorkosJwksService::KEYS.delete(k) }
    WorkosJwksService.reset_rate_limit!

    # Ensure client_id returns our test value
    @original_client_id = ENV["WORKOS_CLIENT_ID"]
    ENV["WORKOS_CLIENT_ID"] = TEST_CLIENT_ID
  end

  teardown do
    WorkosJwksService::KEYS.each_key { |k| WorkosJwksService::KEYS.delete(k) }
    if @original_client_id
      ENV["WORKOS_CLIENT_ID"] = @original_client_id
    else
      ENV.delete("WORKOS_CLIENT_ID")
    end
  end

  test "verifies a valid JWT and returns payload" do
    populate_l1_cache

    payload = build_valid_payload
    token = sign_jwt(payload)

    result = WorkosJwksService.verify_token(token)

    assert_not_nil result
    assert_equal "user_test_abc", result["sub"]
    assert_equal TEST_ISSUER, result["iss"]
  end

  test "returns nil for expired JWT" do
    populate_l1_cache

    payload = build_valid_payload(exp: 1.hour.ago.to_i)
    token = sign_jwt(payload)

    assert_nil WorkosJwksService.verify_token(token)
  end

  test "returns nil for wrong issuer" do
    populate_l1_cache

    payload = build_valid_payload(iss: "https://evil.example.com/")
    token = sign_jwt(payload)

    assert_nil WorkosJwksService.verify_token(token)
  end

  test "returns nil for blank token" do
    assert_nil WorkosJwksService.verify_token("")
    assert_nil WorkosJwksService.verify_token(nil)
  end

  test "returns nil for malformed token" do
    assert_nil WorkosJwksService.verify_token("not.a.jwt")
  end

  test "returns nil for token signed with wrong key" do
    populate_l1_cache

    wrong_key = OpenSSL::PKey::RSA.generate(2048)
    payload = build_valid_payload
    token = JWT.encode(payload, wrong_key, "RS256", { kid: TEST_KID })

    assert_nil WorkosJwksService.verify_token(token)
  end

  test "fetches JWKS from remote on unknown kid" do
    # Don't populate L1 — force remote fetch path
    payload = build_valid_payload
    token = sign_jwt(payload)

    # Stub the remote fetch to return our test key
    stub_jwks_fetch

    result = WorkosJwksService.verify_token(token)

    assert_not_nil result
    assert_equal "user_test_abc", result["sub"]
  ensure
    restore_jwks_fetch
  end

  test "rate-limits JWKS refetches" do
    fetch_count = 0

    original = WorkosJwksService.method(:fetch_jwks)
    WorkosJwksService.define_singleton_method(:fetch_jwks) do
      fetch_count += 1
      original.call
    end

    # Stub the HTTP call itself
    stub_jwks_fetch

    # First call with unknown kid triggers fetch
    unknown_token1 = JWT.encode(build_valid_payload, @rsa_key, "RS256", { kid: "unknown-kid-1" })
    WorkosJwksService.verify_token(unknown_token1)

    first_count = fetch_count

    # Second call immediately should be rate-limited
    unknown_token2 = JWT.encode(build_valid_payload, @rsa_key, "RS256", { kid: "unknown-kid-2" })
    WorkosJwksService.verify_token(unknown_token2)

    assert_equal first_count, fetch_count, "Expected refetch to be rate-limited"
  ensure
    WorkosJwksService.define_singleton_method(:fetch_jwks, original) if original
    restore_jwks_fetch
  end

  test "fetch_jwks runs outside an async reactor" do
    fake_response = FakeJwksResponse.new(200, { keys: [] }.to_json)
    fake_internet = FakeInternet.new(fake_response)

    original_internet_new = Async::HTTP::Internet.method(:new)
    original_get_jwks_url = WorkOS::UserManagement.method(:get_jwks_url)

    Async::HTTP::Internet.define_singleton_method(:new) do |**_kwargs|
      fake_internet
    end
    WorkOS::UserManagement.define_singleton_method(:get_jwks_url) do |_client_id|
      "https://api.workos.test/jwks"
    end

    assert_equal({ "keys" => [] }, WorkosJwksService.send(:fetch_jwks))
    assert_equal [ "https://api.workos.test/jwks" ], fake_internet.requested_urls
    assert_predicate fake_response, :closed?
    assert_predicate fake_internet, :closed?
  ensure
    Async::HTTP::Internet.define_singleton_method(:new, original_internet_new) if original_internet_new
    WorkOS::UserManagement.define_singleton_method(:get_jwks_url, original_get_jwks_url) if original_get_jwks_url
  end

  private

  def build_valid_payload(overrides = {})
    {
      "sub" => "user_test_abc",
      "iss" => TEST_ISSUER,
      "iat" => Time.current.to_i,
      "exp" => 1.hour.from_now.to_i,
      "org_id" => nil
    }.merge(overrides.stringify_keys)
  end

  def sign_jwt(payload)
    JWT.encode(payload, @rsa_key, "RS256", { kid: TEST_KID })
  end

  def populate_l1_cache
    WorkosJwksService::KEYS[TEST_KID] = @rsa_key.public_key
  end

  def stub_jwks_fetch
    jwks_data = { "keys" => [ @jwk.export.transform_keys(&:to_s) ] }

    @original_fetch_jwks = WorkosJwksService.method(:fetch_jwks)
    WorkosJwksService.define_singleton_method(:fetch_jwks) do
      jwks_data
    end
  end

  def restore_jwks_fetch
    return unless @original_fetch_jwks

    WorkosJwksService.define_singleton_method(:fetch_jwks, @original_fetch_jwks)
    @original_fetch_jwks = nil
  end

  class FakeInternet
    attr_reader :requested_urls

    def initialize(response)
      @response = response
      @requested_urls = []
      @closed = false
    end

    def get(url)
      @requested_urls << url
      @response
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  class FakeJwksResponse
    attr_reader :status

    def initialize(status, body)
      @status = status
      @body = body
      @closed = false
    end

    def success?
      status.between?(200, 299)
    end

    def read
      @body
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
