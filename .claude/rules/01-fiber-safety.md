---
paths:
  - "app/models/**"
  - "app/services/**"
  - "app/controllers/**"
  - "app/jobs/**"
  - "app/channels/**"
  - "lib/**"
---

# Fiber Safety

> **Purpose:** Fiber-safe patterns for Falcon server. Thread patterns break silently under fibers.

## NEVER Patterns

| Unsafe Pattern | Why It Breaks | Safe Alternative |
|---------------|---------------|------------------|
| `Thread.current[:key]` | Fibers don't inherit thread locals | `Fiber[:key]` or `CurrentAttributes` |
| `@data \|\|= load_data` | `\|\|=` is not atomic under fibers | Mutex synchronize or eager init |
| `@mutex \|\|= Mutex.new` | Lazy mutex init races under concurrent fibers | Initialize mutex eagerly in constructor |
| `Net::HTTP.get(...)` | Blocks the fiber reactor | `async-http-faraday` |
| `sleep(n)` | Blocks reactor thread | `Async::Task.current.sleep(n)` |
| `@@class_var` | Shared across fibers unsafely | Dependency injection |
| `@hash[key] = value` | Mutable shared hash is not fiber-safe | `Concurrent::Map` |
| `@array << item` | Mutable shared array is not fiber-safe | `Queue` or immutable copy |

## MUST Patterns

- Initialize mutexes eagerly (constructor or class boot), never lazily.
- Use `Fiber[:key]` or `CurrentAttributes` for request context, not `Thread.current`.
- Use `Concurrent::Map` for any shared mutable hash-like state.

## Safe Libraries

- `async-http-faraday` — HTTP client
- `async-redis` — Valkey/Redis client
- `Concurrent::Map` — Fiber-safe hash
- `GoodJob` — Already fiber-safe job backend

## Reference

- Falcon docs: https://github.com/socketry/falcon
- Async gem: https://github.com/socketry/async
