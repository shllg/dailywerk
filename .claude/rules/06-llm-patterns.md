---
paths:
  - "app/services/**"
  - "app/models/agent.rb"
  - "app/models/session.rb"
  - "app/models/message.rb"
  - "app/jobs/**"
---

# LLM Patterns — ruby_llm + AgentRuntime

> **Purpose:** How LLM chat works in this codebase: framework conventions, context management, compaction, and session lifecycle.

## Framework: ruby_llm v1.14+

| Declaration | Model | What it does |
|-------------|-------|--------------|
| `acts_as_chat` | `Session` | Turns Session into a persisted chat; `context_messages:` names the association ruby_llm replays |
| `acts_as_message` | `Message` | Turns Message into a persisted chat message |
| `RubyLLM.chat(model:)` | — | Creates a standalone (non-persisted) chat for compaction / summarization |

## context_messages Override Pattern

`acts_as_chat` normally uses all messages. Session overrides this by declaring `acts_as_chat` first, then redefining the association to exclude compacted messages:

```ruby
acts_as_chat messages: :context_messages,
             message_class: "Message",
             model_class: "RubyLLM::ModelRecord"

has_many :context_messages,
         -> { active.order(:created_at) },
         class_name: "Message",
         foreign_key: :session_id,
         inverse_of: :session
has_many :messages,
         -> { order(:created_at) },
         dependent: :destroy,
         inverse_of: :session
```

`active` scope on `Message` excludes rows where `compacted: true`. Full audit trail lives in `messages`; ruby_llm only replays `context_messages`.

## Runtime Instructions vs Persisted Instructions

| Method | Persists to DB | Use for |
|--------|---------------|---------|
| `with_runtime_instructions(prompt)` | No — in-memory only | System prompt built at runtime (AgentRuntime hot path) |
| `with_instructions(prompt)` | Yes — creates a system Message | One-time setup, not hot paths |

**Always use `with_runtime_instructions` in AgentRuntime.** Never use `with_instructions` in a call path that fires on every user message.

## AgentRuntime Flow

`AgentRuntime#call(user_message)` is the single entry point for all agent LLM calls:

```
1. enqueue_compaction_if_needed    — check context_window_usage >= COMPACTION_THRESHOLD (0.75)
2. ContextBuilder.new(session:, agent:).build  — assemble system prompt
3. session.with_model(agent.model_id, provider: ...)
4. .with_runtime_instructions(context[:system_prompt])   — in-memory system prompt
5. .with_temperature(agent.temperature || 0.7)
6. .ask(user_message, &stream_block)           — streams response
```

`DEFAULT_PROVIDER = :openai_responses`

## Session Lifecycle

```
Session.resolve(agent:, gateway: "web")
  → find_active_session(agent, workspace, gateway)
  → if stale?  → archive! the old session, capture summary
  → create_new_session with inherited_summary from old session
  → ensure model is set (find_or_create RubyLLM::ModelRecord)
```

`stale?` is true when `last_activity_at < inactivity_threshold.ago`. The threshold defaults to `DEFAULT_SESSION_TIMEOUT_HOURS = 4` but can be overridden via `agent.params["session_timeout_hours"]`.

`archive!` sets `status: "archived"` and `ended_at: Time.current`.

New sessions inherit the previous session's `summary` verbatim — this is the lightweight cross-session memory bridge.

## Context Window Management

| Method | Where | What |
|--------|-------|------|
| `estimated_context_tokens` | `Session` | Cheap heuristic: `sum(length(content)) / 4`, used before enqueuing compaction |
| `active_context_tokens` | `Session` | Last message's `input_tokens + output_tokens` (from provider) |
| `context_window_size` | `Session` | `model.context_window` column on `RubyLLM::ModelRecord` — **NOT** metadata JSONB |
| `context_window_usage` | `Session` | `estimated_context_tokens / context_window_size` as Float |
| `COMPACTION_THRESHOLD` | `AgentRuntime` | `0.75` — compaction is enqueued when usage crosses this |

`DEFAULT_CONTEXT_WINDOW_SIZE = 128_000` is used when the model record has no `context_window`.

## Cross-Session Context Bridge (ContextBuilder)

`ContextBuilder#build` assembles the system prompt in three layers:

```
Layer 1: PromptBuilder.new(agent).build        — static agent instructions
Layer 2: "## Previous Context\n\n{session.summary}"   — compacted history
Layer 3: "## Recent Messages (from previous session)\n\n..."  — bridge messages
```

Layer 3 (bridge) is only injected when the new session has no `context_messages` yet. It fetches the `BRIDGE_MESSAGE_LIMIT = 10` most recent user/assistant messages from the immediately preceding archived session and summarizes each with `MessageSummarizer`.

The bridge disappears automatically once the new session accumulates its own messages.

`find_previous_session` uses `Current.without_workspace_scoping` to cross the session boundary cleanly.

## Compaction (CompactionService)

`CompactionService#compact!`:
- Takes all non-system `for_context` messages
- Keeps the newest `PRESERVE_RECENT = 10` messages verbatim
- Summarizes everything older via `RubyLLM.chat(model: compaction_model).ask(...)`
- Marks compacted messages with `compacted: true` (`update_all` for efficiency)
- **Appends** to `session.summary` via `combined_summary`: `[old_summary]\n\n---\n\n[new_summary]`

System messages (`role: "system"`) are always excluded from compaction.

## Compaction Model Resolution

Resolved identically in both `CompactionService` and `ContextBuilder`:

```ruby
agent.params["compaction_model"].presence || agent.model_id || "gpt-4o-mini"
```

`DEFAULT_SUMMARY_MODEL = "gpt-4o-mini"` is the final fallback in `CompactionService`.

## MUST Rules

- **MUST** use `AgentRuntime` for all agent LLM calls — never call `session.ask` directly from a controller or service outside AgentRuntime
- **MUST** use `with_runtime_instructions` for runtime system prompts — not `with_instructions`
- **MUST** run all LLM HTTP calls inside GoodJob background jobs — never in the Falcon request cycle
- **MUST** resolve compaction model per-agent: `agent.params["compaction_model"] || agent.model_id || fallback`
- **MUST** use `context_window_size` from `model.context_window` column (not metadata JSONB)
- **MUST** append to `session.summary` with `\n\n---\n\n` separator, never overwrite

## NEVER Rules

- **NEVER** make LLM HTTP calls in the request cycle — always enqueue a job
- **NEVER** hardcode model names (e.g. `"gpt-4o"`) in service or job code — read from `agent.model_id` or agent params
- **NEVER** overwrite `session.summary` — always append (CompactionService uses `combined_summary`)
- **NEVER** call `session.messages` directly in AgentRuntime — use `context_messages` (excludes compacted)
- **NEVER** use `with_instructions` in a hot path — it persists a Message row on every call
