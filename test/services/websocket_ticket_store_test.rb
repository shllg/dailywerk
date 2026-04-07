# frozen_string_literal: true

require "test_helper"

class WebsocketTicketStoreTest < ActiveSupport::TestCase
  test "issue writes websocket tickets through redis when the cache store is redis-backed" do
    redis = FakeRedis.new
    store = ActiveSupport::Cache::RedisCacheStore.allocate
    store.define_singleton_method(:redis) { FakeRedisPool.new(redis) }
    store.define_singleton_method(:normalize_key) { |key, _options| key }

    with_cache_store(store) do
      WebsocketTicketStore.issue(
        ticket: "ticket-123",
        user_id: "user-123",
        workspace_id: "workspace-123",
        expires_in: 15.seconds
      )

      assert_equal [
        [ "ws_ticket:ticket-123", "{\"user_id\":\"user-123\",\"workspace_id\":\"workspace-123\"}", 15 ]
      ], redis.set_calls
    end
  end

  test "consume uses redis getdel when the cache store is redis-backed" do
    redis = FakeRedis.new
    store = ActiveSupport::Cache::RedisCacheStore.allocate
    store.define_singleton_method(:redis) { FakeRedisPool.new(redis) }
    store.define_singleton_method(:normalize_key) { |key, _options| key }

    with_cache_store(store) do
      WebsocketTicketStore.issue(
        ticket: "ticket-123",
        user_id: "user-123",
        workspace_id: "workspace-123",
        expires_in: 15.seconds
      )

      assert_equal(
        "{\"user_id\":\"user-123\",\"workspace_id\":\"workspace-123\"}",
        WebsocketTicketStore.consume("ticket-123")
      )
      assert_nil WebsocketTicketStore.consume("ticket-123")
      assert_equal [ "ws_ticket:ticket-123", "ws_ticket:ticket-123" ], redis.getdel_calls
    end
  end

  test "falls back to the cache api for non-redis stores" do
    with_cache_store(ActiveSupport::Cache::MemoryStore.new) do
      WebsocketTicketStore.issue(
        ticket: "ticket-456",
        user_id: "user-456",
        workspace_id: "workspace-456",
        expires_in: 15.seconds
      )

      assert_equal(
        "{\"user_id\":\"user-456\",\"workspace_id\":\"workspace-456\"}",
        WebsocketTicketStore.consume("ticket-456")
      )
      assert_nil WebsocketTicketStore.consume("ticket-456")
    end
  end

  private

  def with_cache_store(store)
    original_cache = Rails.cache
    Rails.cache = store
    yield
  ensure
    Rails.cache = original_cache
  end

  class FakeRedisPool
    def initialize(redis)
      @redis = redis
    end

    def then
      yield @redis
    end
  end

  class FakeRedis
    attr_reader :getdel_calls, :set_calls

    def initialize
      @values = {}
      @set_calls = []
      @getdel_calls = []
    end

    def set(key, value, ex:)
      @set_calls << [ key, value, ex ]
      @values[key] = value
      "OK"
    end

    def getdel(key)
      @getdel_calls << key
      @values.delete(key)
    end
  end
end
