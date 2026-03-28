# Architecture — Where to Put Code

> **Purpose:** Canonical placement for every code type.

## Placement Map

| What | Where | Pattern |
|------|-------|---------|
| Data + validations + scopes | `app/models/` | ActiveRecord, UUIDv7 PKs |
| Shared model behavior | `app/models/concerns/` | `ActiveSupport::Concern` |
| Business logic | `app/services/` | Service objects, single responsibility |
| API endpoints | `app/controllers/api/v1/` | Skinny controllers, strong params, JSON only |
| Background work | `app/jobs/` | GoodJob, idempotent, with timeouts |
| WebSocket channels | `app/channels/` | ActionCable channels |
| JSON serialization | `app/serializers/` | Response shaping |
| React components | `frontend/src/components/` | TypeScript + Tailwind |
| React pages/routes | `frontend/src/pages/` | React Router |
| Custom hooks | `frontend/src/hooks/` | Reusable React hooks |
| API client functions | `frontend/src/services/` | Typed fetch wrappers |
| TypeScript types | `frontend/src/types/` | Shared type definitions |

## Service Object Pattern

```ruby
class SomeService
  def initialize(user:, **deps)
    @user = user
  end

  def call
    # Single public method, returns result
  end
end
```

## Controller Pattern

```ruby
class Api::V1::SomeController < ApplicationController
  def index
    # Auth check → params → call service → render JSON
  end

  private

  def some_params
    params.require(:some).permit(:allowed, :fields)
  end
end
```

## Principles

- **Fat model / skinny controller** — Controllers: auth, params, service call, render. Models: validations, scopes, associations.
- **Service objects over callbacks** — Prefer explicit service objects for multi-step business logic. Keep ActiveRecord callbacks simple (e.g., setting defaults).
- **No God objects** — If a class grows beyond ~200 lines, extract concerns or services.
