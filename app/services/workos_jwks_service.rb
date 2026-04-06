# frozen_string_literal: true

require "jwt"
require "net/http"
require "uri"
require "json"

# Verifies WorkOS-issued JWTs using cached JWKS public keys.
#
# Caching is two-tier:
# - **L1**: in-process `Concurrent::Map` keyed by `kid` (fiber-safe, no TTL —
#   keys rarely rotate; an unknown `kid` triggers a refresh).
# - **L2**: `Rails.cache` (Valkey, 1-hour TTL) for cross-process consistency.
#
# On an unknown `kid`, JWKS are refetched from WorkOS once per minute max
# to prevent DoS via forged JWT headers.
class WorkosJwksService
  # L1 cache: kid → OpenSSL::PKey::RSA  (fiber-safe, eagerly initialized)
  KEYS = Concurrent::Map.new

  # Minimum interval between JWKS refetches (DoS protection).
  REFETCH_COOLDOWN = 60 # seconds

  L2_CACHE_KEY = "workos:jwks"
  L2_CACHE_TTL = 1.hour

  class << self
    # Verifies a WorkOS JWT and returns the decoded payload.
    #
    # @param jwt_string [String] the raw JWT from the Authorization header
    # @return [Hash, nil] the decoded payload, or nil if verification fails
    def verify_token(jwt_string)
      return nil if jwt_string.blank?

      header = decode_header(jwt_string)
      return nil unless header

      kid = header["kid"]
      return nil if kid.blank?

      key = find_key(kid)
      return nil unless key

      payload, = JWT.decode(
        jwt_string,
        key,
        true,
        algorithm: "RS256",
        iss: "https://api.workos.com/",
        verify_iss: true,
        aud: WorkOS::DailyWerk.client_id,
        verify_aud: true,
        verify_expiration: true,
        verify_iat: true
      )

      payload
    rescue JWT::DecodeError, JWT::ExpiredSignature, JWT::InvalidIssuerError,
           JWT::InvalidAudError, JWT::InvalidIatError
      nil
    end

    # Eagerly fetches JWKS and populates both caches.
    # Called from the WorkOS initializer at boot.
    #
    # @return [void]
    def warm_cache
      populate_from_jwks(fetch_jwks)
    rescue StandardError => e
      Rails.logger.warn "WorkosJwksService: failed to warm JWKS cache: #{e.message}"
    end

    # Resets internal rate-limit state. Only for use in tests.
    #
    # @return [void]
    def reset_rate_limit!
      @last_refetch_at = nil
    end

    private

    # Finds a public key by kid, checking L1 → L2 → remote.
    #
    # @param kid [String]
    # @return [OpenSSL::PKey::RSA, nil]
    def find_key(kid)
      # L1 hit
      key = KEYS[kid]
      return key if key

      # L2 hit — populate L1
      l2_keys = Rails.cache.read(L2_CACHE_KEY)
      if l2_keys.is_a?(Hash) && l2_keys[kid]
        key = OpenSSL::PKey::RSA.new(l2_keys[kid])
        KEYS[kid] = key
        return key
      end

      # Remote fetch (rate-limited)
      refetch_jwks
      KEYS[kid]
    end

    # Fetches JWKS from WorkOS and populates both caches.
    # Rate-limited to prevent DoS via forged kid headers.
    #
    # @return [void]
    def refetch_jwks
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      last = @last_refetch_at || 0

      if (now - last) < REFETCH_COOLDOWN
        Rails.logger.debug "WorkosJwksService: refetch skipped (cooldown)"
        return
      end

      @last_refetch_at = now
      populate_from_jwks(fetch_jwks)
    rescue StandardError => e
      Rails.logger.warn "WorkosJwksService: JWKS refetch failed: #{e.message}"
    end

    # Downloads the JWKS JSON from WorkOS.
    #
    # @return [Hash] parsed JWKS response
    def fetch_jwks
      client_id = WorkOS::DailyWerk.client_id
      raise "WORKOS_CLIENT_ID not configured" if client_id.blank?

      jwks_url = WorkOS::UserManagement.get_jwks_url(client_id)
      uri = URI.parse(jwks_url)

      response = Net::HTTP.get_response(uri)
      raise "JWKS fetch failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end

    # Parses JWKS response and populates L1 + L2 caches.
    #
    # @param jwks_data [Hash] parsed JWKS JSON with "keys" array
    # @return [void]
    def populate_from_jwks(jwks_data)
      keys = jwks_data["keys"]
      return if keys.blank?

      l2_hash = {}

      keys.each do |jwk_data|
        kid = jwk_data["kid"]
        next if kid.blank?

        jwk = JWT::JWK.new(jwk_data)
        public_key = jwk.public_key
        KEYS[kid] = public_key
        l2_hash[kid] = public_key.to_pem
      end

      Rails.cache.write(L2_CACHE_KEY, l2_hash, expires_in: L2_CACHE_TTL) if l2_hash.any?
    end

    # Decodes just the JWT header without verification.
    #
    # @param jwt_string [String]
    # @return [Hash, nil]
    def decode_header(jwt_string)
      header_segment = jwt_string.split(".").first
      return nil unless header_segment

      JSON.parse(Base64.urlsafe_decode64(header_segment))
    rescue JSON::ParserError, ArgumentError
      nil
    end
  end
end
