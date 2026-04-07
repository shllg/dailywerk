# frozen_string_literal: true

# Stores one-time ActionCable authentication tickets.
#
# In environments backed by RedisCacheStore, tickets use Redis `SET` and
# `GETDEL` so consume is atomic. Other cache stores fall back to the regular
# cache API for testability.
class WebsocketTicketStore
  KEY_PREFIX = "ws_ticket".freeze

  class << self
    # @param ticket [String]
    # @param user_id [String]
    # @param workspace_id [String]
    # @param expires_in [ActiveSupport::Duration, Numeric]
    # @return [void]
    def issue(ticket:, user_id:, workspace_id:, expires_in:)
      payload = { user_id:, workspace_id: }.to_json

      if (store = redis_cache_store)
        store.redis.then do |redis|
          redis.set(normalized_key(store, ticket), payload, ex: expires_in.to_i)
        end
      else
        Rails.cache.write(cache_key(ticket), payload, expires_in:)
      end
    end

    # @param ticket [String]
    # @return [String, nil]
    def consume(ticket)
      if (store = redis_cache_store)
        store.redis.then do |redis|
          redis.getdel(normalized_key(store, ticket))
        end
      elsif Rails.cache.respond_to?(:read_and_delete)
        Rails.cache.read_and_delete(cache_key(ticket))
      else
        data = Rails.cache.read(cache_key(ticket))
        Rails.cache.delete(cache_key(ticket))
        data
      end
    end

    private

    # @param ticket [String]
    # @return [String]
    def cache_key(ticket)
      "#{KEY_PREFIX}:#{ticket}"
    end

    # @param store [ActiveSupport::Cache::RedisCacheStore]
    # @param ticket [String]
    # @return [String]
    def normalized_key(store, ticket)
      store.send(:normalize_key, cache_key(ticket), nil)
    end

    # @return [ActiveSupport::Cache::RedisCacheStore, nil]
    def redis_cache_store
      store = Rails.cache
      return store if store.is_a?(ActiveSupport::Cache::RedisCacheStore)

      nil
    end
  end
end
