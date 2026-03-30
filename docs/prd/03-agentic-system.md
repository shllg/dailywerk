---
type: prd
title: Agentic System
domain: agents
created: 2026-03-28
updated: 2026-03-30
status: canonical
depends_on:
  - prd/01-platform-and-infrastructure
  - prd/02-integrations-and-channels
  - prd/04-billing-and-operations
implemented_by:
  - rfc/2026-03-29-simple-chat-conversation
---

# DailyWerk — Agentic System

> The brain: agents, runtime, memory, tools, sessions, streaming.
> For database schema: see [01-platform-and-infrastructure.md §5](./01-platform-and-infrastructure.md#5-canonical-database-schema).
> For channel adapters and vault sync: see [02-integrations-and-channels.md](./02-integrations-and-channels.md).
> For BYOK, MCP, cost tracking, and GoodJob config: see [04-billing-and-operations.md](./04-billing-and-operations.md).

**Implementation status:** [RFC 002](../rfc-open/2026-03-29-simple-chat-conversation.md) implements the first slice — simple chat with a single agent (no tools, no memory, no handoffs). Sections below describe the full target architecture.

---

## 1. ruby_llm Framework Foundation

ruby_llm (v1.14+) provides three critical primitives:

1. **`RubyLLM::Chat`** — Manages a conversation as a flat message array with fluent configuration: `.with_tool(Weather).with_instructions("...").with_temperature(0.2)`. Handles the tool-execution loop internally: when the LLM returns a tool call, ruby_llm executes the Ruby `Tool#execute` method, feeds the result back, and loops until the model produces text.

2. **`RubyLLM::Agent`** — Wraps Chat in a class-based DSL with `model`, `instructions`, `tools`, and `temperature` macros, plus Rails persistence via `chat_model`.

3. **ActiveRecord integration** — `acts_as_chat`, `acts_as_message`, `acts_as_tool_call` persist conversations with streaming-first design: creating empty assistant messages early for DOM targeting, then updating as chunks arrive.

### Dual-Provider Strategy

- **Standard providers** (Anthropic, OpenAI, Gemini, etc.): Multi-model flexibility via the same `chat.ask` API. Used for all non-OpenAI models.
- **OpenAI Responses API** (`ruby_llm-responses_api`): Server-side conversation state via `previous_response_id` (only the new message is sent each turn), built-in hosted tools (web search, code interpreter), automatic server-side compaction. A single `response_id` column on messages enables session resumption.

Agent definitions can switch providers without code changes — the runtime resolves the provider from the agent config.

---

## 2. Agent Model

Agents are **fully data-driven** — defined by database rows, not Ruby classes. The `Agent` model (schema in [01 §5.3](./01-platform-and-infrastructure.md#53-agent-tables)) stores everything: identity, soul, instructions, model, tools, thinking config, handoff targets, and DailyWerk-specific access controls.

### Agent Configuration

Each user can have multiple agents with distinct roles, tools, memory, and access levels:

- **Default agent**: `is_default = true`. General-purpose assistant, full tool access, shared memory.
- **Specialist agents**: Research agent (web search + vault, `read_shared` memory), Diary agent (diary vault only, `isolated` memory), Health Tracker (nutrition/sport tools, `isolated` memory).

### Memory Isolation Modes

Per-agent memory scoping (see [§7](#7-memory-architecture) for full memory architecture):

- `shared`: Agent reads/writes shared long-term memory. Default for general assistants.
- `isolated`: Agent has its own long-term memory. For diary agent, confidential agent.
- `read_shared`: Agent can read shared memory but writes to its own. For research agent that consumes context but doesn't pollute shared memory.

### Memory Isolation — Read/Write Matrix

| Mode | Reads | Writes (agent_id) |
|------|-------|--------------------|
| `shared` | Shared pool (agent_id: nil) + own (agent_id: self) | Shared pool (agent_id: nil) |
| `isolated` | Own only (agent_id: self) | Own only (agent_id: self) |
| `read_shared` | Shared pool (agent_id: nil) + own (agent_id: self) | Own only (agent_id: self) |

**Note**: `read_shared` does NOT read other agents' isolated memories — only the shared pool + its own.

### Resolved Instructions

The system prompt is assembled from multiple agent fields in priority order:

| Source | When Used | Description |
|--------|-----------|-------------|
| `instructions_path` (ERB) | If set (admin-only) | Template file rendered with agent context. Validated against allowlist. |
| `instructions` (text) | Default fallback | Free-text system prompt. |
| `soul` | If present | Personality, tone, boundaries — appended as "## Soul" section. |
| `identity` (jsonb) | If present | Structured persona, tone, constraints — appended as separate sections. |

Key behaviors:
- `thinking_config` returns extended thinking params when `thinking.enabled` is true.
- `tool_classes` resolves tool name strings to Ruby classes via `ToolRegistry`.
- `handoff_agents` resolves `handoff_targets` slugs to active Agent records for the same user.

> **Initial implementation:** [RFC 002](../rfc-open/2026-03-29-simple-chat-conversation.md) implements a minimal Agent model where `resolved_instructions` simply returns `instructions.to_s`. Full soul/identity/ERB template support ships in a later RFC.

### Admin / Config Tools (Master Chat)

Users can configure agents **via conversation** instead of (or in addition to) a web UI. The default agent has access to admin tools:

- `update_soul` — Modify an agent's personality/tone.
- `update_instructions` — Modify operating procedures.
- `create_agent` — Create a new agent, bind to channel.
- `update_agent_tools` — Enable/disable tools for an agent.
- `update_agent_routing` — Change which channels route to which agents.
- `list_agents` — Show all configured agents and their bindings.

These are gated by a confirmation step. Changes take effect on the next session start for the affected agent — no mid-session hot-swap (too risky for context coherence).

### Agent CRUD API

Agents are manageable via REST API (`Api::V1::AgentsController`) for the dashboard. Standard create/update actions with strong parameters. `instructions_path` is NOT user-settable — admin-only field. Deferred until multi-agent management ships (RFC 002 uses a single seeded default agent).

---

## 3. Agent Runtime (ReAct Loop)

The core runtime is a single-threaded ReAct loop — the same pattern Claude Code and Codex use — wrapped in a service object. **Radical simplicity in the core loop outperforms complex multi-agent swarms.**

### Runtime Flow

```
AgentRuntime.run(user_message)
  │
  ├─ 0. BudgetEnforcer.check!(user:)
  ├─ 1. compact_if_needed! (at 75% context window)
  ├─ 2. inject_memory_context (memories, archives, profile, daily logs)
  ├─ 3. @chat.ask(user_message, &stream_block)  ← ReAct loop
  │       └─ LLM → tool call → execute → feed result → loop until text
  └─ 4. postprocess: UsageRecorder, MemoryExtractionJob, update tokens
```

### Key Design Points

| Constant | Value | Rationale |
|----------|-------|-----------|
| `MAX_TOOL_ITERATIONS` | 25 | Prevents runaway tool loops |
| `COMPACTION_THRESHOLD` | 0.75 | Trigger compaction at 75% of context window |
| `MAX_HANDOFF_DEPTH` | 3 | Prevents infinite A↔B handoff cycles |

**Chat construction** (`build_chat`):
- Session messages auto-loaded by ruby_llm's `acts_as_chat` persistence
- BYOK: `LlmContextBuilder.build(user:)` creates isolated config with user's API keys
- Tools resolved from: local tools (ToolRegistry) + MCP tools (McpClientManager) + HandoffTool
- Event handlers wired for tool call recording, token counting
- Responses API provider gets server-side compaction enabled

**Instructions** (`load_instructions`): Combines `agent.resolved_instructions` with current context (user, channel, session, available handoff agents).

**Memory injection** (`inject_memory_context`): Injects 4 types of cross-session context as system messages — memories (Layer 2), archived conversation summaries (Layer 3), synthesized user profile (Layer 5), and daily logs. All managed by `MemoryRetrievalService` within token budgets.

**Post-processing**: Records usage for billing, extracts memories asynchronously via `MemoryExtractionJob`, and atomically updates session token counts.

> **Initial implementation:** [RFC 002](../rfc-open/2026-03-29-simple-chat-conversation.md) implements `SimpleChatService` — a minimal runtime with no tools, no memory injection, no budget checks, no compaction. Just: build chat → ask → stream. The full `AgentRuntime` with tool loop and memory ships in later RFCs.

---

## 4. Multi-Agent Routing & Handoffs

The system supports both **hierarchical routing** (orchestrator dispatches to sub-agents) and **peer-to-peer routing** (any agent hands off to another via `HandoffTool`).

### HandoffTool

```ruby
# app/tools/handoff_tool.rb
class HandoffTool < RubyLLM::Tool
  description "Transfer this conversation to another specialized agent. " \
              "Use when the user's request falls outside your expertise."

  param :target_agent, desc: "The slug of the agent to hand off to"
  param :reason, desc: "Why you are handing off (passed to the next agent)"
  param :context_summary, desc: "Key context the next agent needs to know"

  def initialize(agent:, session:, user:, depth: 0)
    @source_agent = agent
    @session = session
    @user = user
    @depth = depth
  end

  def execute(target_agent:, reason:, context_summary:)
    target = Agent.find_by(slug: target_agent, user: @user, active: true)
    return { error: "Unknown agent '#{target_agent}'" } unless target
    return { error: "Cannot hand off to '#{target_agent}'" } unless target.slug.in?(@source_agent.handoff_targets)
    return { error: "Max handoff depth (#{AgentRuntime::MAX_HANDOFF_DEPTH}) reached" } if @depth >= AgentRuntime::MAX_HANDOFF_DEPTH

    # Record the handoff
    @session.messages.create!(
      role: "system",
      content: "--- Handoff: #{@source_agent.slug} → #{target.slug} ---\nReason: #{reason}\nContext: #{context_summary}",
      agent_slug: @source_agent.slug
    )

    # Build a new runtime for the target agent
    target_session = Session.find_or_create_by!(
      agent: target, channel: @session.channel, status: "active"
    ) { |s| s.user = @user }

    runtime = AgentRuntime.new(session: target_session, user: @user, handoff_depth: @depth + 1)
    response = runtime.run(context_summary)

    { agent: target.slug, response: response.content }
  end
end
```

### Agent Channel Bindings

Messages are routed to agents based on channel, thread, and routing rules (schema in [01 §5.3](./01-platform-and-infrastructure.md#53-agent-tables)):

**Routing logic**: On inbound message, find matching bindings (channel + account + thread). If multiple agents match, route to highest priority. For multi-agent routing (message relevant to >1 agent), the primary agent handles the response but can spawn sub-agent sessions for parallel processing.

---

## 5. Session Management

Sessions are the unit of conversation continuity. Schema in [01 §5.4](./01-platform-and-infrastructure.md#54-channel-session--message-tables).

### Session Model

The Session model uses ruby_llm's `acts_as_chat` for automatic message persistence and LLM context management.

| Association | Type | Description |
|-------------|------|-------------|
| `user` | belongs_to | Owner (required) |
| `agent` | belongs_to | Which agent handles this session (required) |
| `channel` | belongs_to | Which channel this session is on (deferred — see RFC 002) |
| `messages` | has_many | Conversation messages |
| `notes` | has_many | Agent-created notes (nullified on session delete) |
| `memory_entries` | has_many | Extracted memories (nullified on session delete) |

Key methods:
- `context_window_usage` — Returns ratio of `total_tokens / context_window_size`. Used by compaction (§8).
- `context_window_size` — Looks up the model's context window from ruby_llm's model registry.

> **Initial implementation:** [RFC 002](../rfc-open/2026-03-29-simple-chat-conversation.md) implements a minimal Session without `channel` association, notes, or memory entries. `context_window_usage` is deferred until compaction ships.

### Lifecycle

1. **Creation**: New session per new context (channel + agent combination).
2. **Continuation**: Messages in same context append to existing session. One active session per agent × channel (enforced by unique index).
3. **Compaction**: When approaching context limit (see [§8](#8-compaction)).
4. **Archival**: Inactive >7 days → archived. Searchable but not loaded into context (GoodJob cron in [04 §8](./04-billing-and-operations.md#8-goodjob-configuration)).
5. **Cross-channel isolation**: Each channel × agent gets its own session. Signal doesn't bleed into Telegram.

**Session replay**: Archived sessions remain fully searchable. Admin dashboard shows session timeline. Useful for debugging agent behavior.

---

## 6. Tool System

Tools are capabilities, configurable per agent via `tool_names`. The ToolRegistry maps string names to classes and handles dependency injection.

```ruby
# app/services/tool_registry.rb
class ToolRegistry
  TOOLS = {
    "notes"        => NotesTool,
    "memory"       => MemoryTool,
    "vault"        => VaultTool,
    "handoff"      => HandoffTool,
    "web_search"   => WebSearchTool,
    "send_message" => SendMessageTool,
    # Integration tools
    "email_read"   => EmailReadTool,
    "email_send"   => EmailSendTool,
    "email_label"  => EmailLabelTool,
    "email_archive" => EmailArchiveTool,
    "calendar_read" => CalendarReadTool,
    "calendar_create" => CalendarCreateTool,
    "calendar_update" => CalendarUpdateTool,
    "todo_create"  => TodoCreateTool,
    "todo_update"  => TodoUpdateTool,
    "todo_complete" => TodoCompleteTool,
    "todo_list"    => TodoListTool,
    # Admin tools (default agent only)
    "update_soul"  => UpdateSoulTool,
    "update_instructions" => UpdateInstructionsTool,
    "create_agent" => CreateAgentTool,
    "update_agent_tools" => UpdateAgentToolsTool,
    "list_agents"  => ListAgentsTool
  }.freeze

  def self.resolve(name)
    TOOLS[name]
  end

  def self.build(names, user:, session:)
    names.filter_map do |name|
      klass = resolve(name)
      next unless klass
      if klass.instance_method(:initialize).arity != 0
        klass.new(user: user, session: session)
      else
        klass.new
      end
    end
  end
end
```

### Core Tools

**NotesTool** — Persistent agent notes with semantic search. Create, search, update, list, delete. Each note gets an embedding via [GenerateEmbeddingJob](./04-billing-and-operations.md#8-goodjob-configuration).

```ruby
# app/tools/notes_tool.rb
class NotesTool < RubyLLM::Tool
  description "Create, search, and manage persistent notes for the user."

  params do
    string :action, description: "create, search, update, list, delete",
           enum: %w[create search update list delete]
    string :title
    string :content, description: "Note content in markdown"
    string :query, description: "Search query (for search)"
    string :note_id, description: "Note UUID (for update/delete)"
    array  :tags, of: :string
  end

  def initialize(user:, session:)
    @user = user; @session = session
  end

  def execute(action:, **params)
    case action
    when "create"
      note = @user.notes.create!(
        title: params[:title], content: params[:content],
        tags: params[:tags] || [], session: @session
      )
      GenerateEmbeddingJob.perform_later("Note", note.id, user_id: @user.id)
      { id: note.id, title: note.title, status: "created" }
    when "search"
      results = @user.notes
        .nearest_neighbors(:embedding, RubyLLM.embed(params[:query]).vectors, distance: "cosine")
        .limit(5)
      results.map { |n| { id: n.id, title: n.title, content: n.content.truncate(500) } }
    when "list"
      @user.notes.order(updated_at: :desc).limit(20)
           .pluck(:id, :title, :tags, :updated_at)
           .map { |id, title, tags, at| { id:, title:, tags:, updated_at: at.iso8601 } }
    when "update"
      note = @user.notes.find(params[:note_id])
      note.update!(params.slice(:title, :content, :tags).compact)
      GenerateEmbeddingJob.perform_later("Note", note.id, user_id: @user.id)
      { id: note.id, status: "updated" }
    when "delete"
      @user.notes.find(params[:note_id]).destroy!
      { status: "deleted" }
    end
  rescue ActiveRecord::RecordNotFound
    { error: "Note not found" }
  end
end
```

**MemoryTool** — Store and retrieve explicit long-term memories. Uses multi-signal scoring (recency + importance + relevance).

```ruby
# app/tools/memory_tool.rb
class MemoryTool < RubyLLM::Tool
  description "Store and retrieve explicit long-term memories about the user."

  params do
    string :action, enum: %w[store recall forget list]
    string :content, description: "Memory content to store"
    string :category, description: "preference, fact, rule, instruction, context"
    string :query, description: "Search query for recall"
    integer :importance, description: "1-10 importance score"
    string :memory_id, description: "Memory UUID (for forget)"
  end

  def initialize(user:, session:)
    @user = user; @session = session
  end

  def execute(action:, **params)
    case action
    when "store"
      mem = @user.memory_entries.create!(
        content: params[:content],
        category: params[:category] || "general",
        importance: params[:importance] || 5,
        agent: agent_for_store,
        session: @session,
        source: "agent"
      )
      GenerateEmbeddingJob.perform_later("MemoryEntry", mem.id, user_id: @user.id)
      { id: mem.id, status: "stored" }
    when "recall"
      query_embedding = RubyLLM.embed(params[:query]).vectors
      results = scoped_memories.active
        .nearest_neighbors(:embedding, query_embedding, distance: "cosine")
        .limit(10)

      scored = results.map do |m|
        recency = Math.exp(-0.005 * (Time.current - m.updated_at).to_f / 3600)
        importance_norm = m.importance / 10.0
        relevance = 1.0 - m.neighbor_distance
        score = 0.3 * recency + 0.3 * importance_norm + 0.4 * relevance
        { id: m.id, content: m.content, category: m.category, score: score.round(3) }
      end
      scored.sort_by { |s| -s[:score] }.first(5)
    when "forget"
      @user.memory_entries.find(params[:memory_id]).update!(active: false)
      { status: "deactivated" }
    when "list"
      scoped_memories.active.order(importance: :desc, updated_at: :desc).limit(20)
           .map { |m| { id: m.id, content: m.content.truncate(200), category: m.category, importance: m.importance } }
    end
  end

  private

  def agent_for_store
    case @session.agent.memory_isolation
    when "shared"      then nil            # Write to shared pool
    when "isolated"    then @session.agent  # Write to own
    when "read_shared" then @session.agent  # Write to own
    end
  end

  # Respect memory isolation modes
  def scoped_memories
    case @session.agent.memory_isolation
    when "shared"
      @user.memory_entries.where(agent_id: [nil, @session.agent_id])
    when "isolated"
      @user.memory_entries.where(agent: @session.agent)
    when "read_shared"
      @user.memory_entries.where(agent_id: [nil, @session.agent_id])  # Shared + own only
    end
  end
end
```

**VaultTool** — Manage user's vault files with hybrid search (semantic + FTS), backlinks, and graph traversal. Operates on local checkout; [VaultSyncWorker](./02-integrations-and-channels.md#4-obsidian-vault-sync) pushes to S3.

```ruby
# app/tools/vault_tool.rb
class VaultTool < RubyLLM::Tool
  description "Read, write, and search the user's personal knowledge vault."

  params do
    string :action, enum: %w[read write list search backlinks]
    string :path, description: "File path like 'diary/2026-03-28.md'"
    string :content, description: "Markdown content to write"
    string :query, description: "Search query (semantic + full-text)"
    string :vault_id, description: "Vault UUID (defaults to primary)"
  end

  def initialize(user:, session:)
    @user = user; @session = session
  end

  def execute(action:, **params)
    vault = resolve_vault(params[:vault_id])
    return { error: "No access to this vault" } unless vault

    case action
    when "read"
      file = vault.vault_files.find_by!(path: params[:path])
      content = File.read(local_path(vault, params[:path]))
      backlinks = VaultLink.where(target: file).includes(:source).map { |l| l.source.path }
      { path: params[:path], content: content, backlinks: backlinks }
    when "write"
      full_path = local_path(vault, params[:path])
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, params[:content])
      # VaultSyncWorker will pick up changes via inotify
      { path: params[:path], status: "written" }
    when "list"
      vault.vault_files.order(:path).limit(100)
           .pluck(:path, :size_bytes, :last_modified)
           .map { |path, size, modified| { path:, size:, modified: modified&.iso8601 } }
    when "search"
      # Delegates to hybrid search (see 02-integrations §7)
      results = hybrid_search(vault, params[:query])
      results.map { |c| { path: c.file_path, chunk: c.chunk_idx, content: c.content.truncate(300) } }
    when "backlinks"
      file = vault.vault_files.find_by!(path: params[:path])
      VaultLink.where(target: file).includes(:source).map do |link|
        { source_path: link.source.path, context: link.context, type: link.link_type }
      end
    end
  rescue ActiveRecord::RecordNotFound
    { error: "File not found" }
  end

  private

  def resolve_vault(vault_id)
    if vault_id
      @user.vaults.find_by(id: vault_id)
    else
      @user.vaults.first  # Primary vault
    end
  end

  def local_path(vault, path)
    base = File.expand_path(File.join("/data/vaults", @user.id, vault.slug))
    full = File.expand_path(path, base)
    raise ArgumentError, "Path traversal detected" unless full.start_with?(base + File::SEPARATOR)
    full
  end

  def hybrid_search(vault, query)
    embedding = RubyLLM.embed(query).vectors
    semantic = vault.vault_chunks
      .nearest_neighbors(:embedding, embedding, distance: "cosine").limit(10)
    fulltext = vault.vault_chunks
      .where("tsv @@ plainto_tsquery('english', ?)", query).limit(10)

    rrf_scores = Hash.new(0.0)
    semantic.each_with_index { |c, i| rrf_scores[c.id] += 1.0 / (60 + i) }
    fulltext.each_with_index { |c, i| rrf_scores[c.id] += 1.0 / (60 + i) }

    chunk_ids = rrf_scores.sort_by { |_, s| -s }.first(5).map(&:first)
    VaultChunk.where(id: chunk_ids).index_by(&:id).values_at(*chunk_ids).compact
  end
end
```

### Tool Summary

| Category | Tools | Available To |
|----------|-------|-------------|
| **Core** | `notes`, `memory`, `send_message` | All agents |
| **Vault** | `vault` (read/write/list/search/backlinks) | Agents with vault_access |
| **Email** | `email_read`, `email_send`, `email_label`, `email_archive` | Configurable per agent |
| **Calendar** | `calendar_read`, `calendar_create`, `calendar_update` | Configurable per agent |
| **Tasks** | `todo_create`, `todo_update`, `todo_complete`, `todo_list` | Configurable per agent |
| **Search** | `web_search` (Brave Search API) | Configurable per agent |
| **Admin** | `update_soul`, `update_instructions`, `create_agent`, `update_agent_tools`, `list_agents` | Default/master agent only |
| **MCP** | User-configured external tools | Per agent via `enabled_mcps` |

---

## 7. Memory Architecture

**Critical distinction**: Agent memory ≠ user vault data. Memory is system-managed context for agents. Vault is user-owned data that survives agent deletion.

### Five-Layer Model

```
┌─────────────────────────────────────────────────────────┐
│  AGENT MEMORY (PostgreSQL only)                        │
│  Private to agent(s). Managed by system.               │
│                                                         │
│  Layer 1 — Session context (ephemeral):                 │
│    Channel type, device info, current agent, active     │
│    tools. Injected as system message at session start.  │
│    Never persisted beyond the session.                  │
│                                                         │
│  Layer 2 — Explicit memories (persistent):              │
│    memory_entries table. Curated key facts.             │
│    Per-agent or shared (based on memory_isolation).     │
│    Retrieved by token budget, ordered by importance     │
│    + recency + relevance scoring.                       │
│                                                         │
│  Layer 3 — Conversation summaries (cross-session):      │
│    conversation_archives table. After session goes      │
│    cold (>7d), summarized into key facts with           │
│    embeddings. Top 5 most relevant injected at          │
│    session start via semantic search.                   │
│                                                         │
│  Layer 4 — Active session messages (sliding window):    │
│    Current session's messages. Recent stay verbatim;    │
│    older ones get summarized by compaction (§8).        │
│                                                         │
│  Layer 5 — User knowledge synthesis (periodic):         │
│    Background job runs daily per user, synthesizing     │
│    all memories, notes, and recent conversations into   │
│    a dense 2-3 paragraph user profile stored in         │
│    users.synthesized_profile. Cheap to inject.          │
│                                                         │
│  Tier 2 — Daily logs:                                   │
│    daily_logs table. Auto-written by agent.             │
│    Today + yesterday loaded per session.                │
│    Nightly: summarize → promote durable facts to        │
│    Layer 2 (memory_entries).                            │
│    Weekly: consolidate, deduplicate, prune stale.       │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  USER VAULT DATA (S3 + pgvector index)                 │
│  Owned by user. Agents read/write per vault_access.     │
│  Diary, research, nutrition logs, attachments.          │
│  Survives agent deletion. Exportable.                  │
│  Searchable via vault tool (pgvector + FTS).           │
│  See 02-integrations §4 for sync mechanism.            │
└─────────────────────────────────────────────────────────┘
```

### Memory Retrieval Service

Manages token budgets for context injection:

```ruby
# app/services/memory_retrieval_service.rb
class MemoryRetrievalService
  TOKEN_BUDGET = {
    system_instructions: 0.15,   # 15% of context window
    memories:            0.12,   # 12%
    vault_context:       0.18,   # 18%
    daily_logs:          0.05,   # 5%
    response_reserve:    0.25,   # 25%
    # Remaining ~25% is managed by ruby_llm for conversation history
  }.freeze

  def initialize(session:, user:)
    @session = session
    @user = user
    @agent = session.agent
    @window = session.context_window_size
  end

  def build_context
    budget = TOKEN_BUDGET.transform_values { |pct| (@window * pct).to_i }

    {
      memories: fetch_memories(budget[:memories]),
      archives: fetch_relevant_archives(budget[:vault_context]),
      user_profile: @user.synthesized_profile&.truncate(budget[:memories] * 4),
      daily_logs: fetch_daily_logs
    }
  end

  private

  def fetch_memories(token_budget)
    memories = scoped_memories.active
      .order(importance: :desc, updated_at: :desc)

    # Respect token budget instead of fixed limit
    kept = []
    remaining = token_budget
    memories.find_each do |mem|
      est = (mem.content.length / 4.0).ceil
      break if remaining - est < 0
      kept << mem
      remaining -= est
      mem.update_columns(access_count: mem.access_count + 1, last_accessed_at: Time.current)
    end
    kept
  end

  def scoped_memories
    case @agent.memory_isolation
    when "shared"
      @user.memory_entries.where(agent_id: [nil, @agent.id])
    when "isolated"
      @user.memory_entries.where(agent: @agent)
    when "read_shared"
      @user.memory_entries.where(agent_id: [nil, @agent.id])  # Shared + own only
    end
  end

  def fetch_relevant_archives(token_budget)
    return [] if @session.messages.count < 3
    recent_content = @session.messages.last(3).map(&:content).join(" ")
    embedding = RubyLLM.embed(recent_content).vectors
    ConversationArchive.nearest_neighbors(:embedding, embedding, distance: "cosine").limit(5)
  end

  def fetch_daily_logs
    DailyLog.where(user: @user, agent: @agent, date: [Date.current, Date.yesterday])
            .order(:date)
  end

end
```

### Background Memory Processes

All scheduled via GoodJob cron (see [04 §8](./04-billing-and-operations.md#8-goodjob-configuration)):

- **Nightly**: Summarize yesterday's daily logs → promote durable facts to Layer 2 (`memory_entries`).
- **Weekly**: Review Layer 2 entries → consolidate, deduplicate, prune stale facts.
- **Session archival**: Archive sessions inactive >7 days. Generate summary + key facts + embedding → `conversation_archives`.
- **Daily synthesis**: Per user, synthesize all memories + recent conversations → `users.synthesized_profile` (Layer 5).
- **Embedding refresh**: Every 15min, generate embeddings for records missing them.

---

## 8. Compaction

Two distinct mechanisms at different timescales.

### Context-Window Compaction

Triggers at 75% context window usage. Summarizes old messages to keep conversations within token limits.

```ruby
# app/services/compaction_service.rb
class CompactionService
  # Configurable — BYOK users without OpenAI key need an alternative
  SUMMARY_MODEL = Rails.application.config.x.compaction_model || "gpt-4o-mini"
  PRESERVE_RECENT = 10
  PROTECTED_PATTERNS = [
    /```[\s\S]+?```/,              # Code blocks
    /error|exception|fail/i,       # Error context
    /decision:|decided:|agreed:/i  # Key decisions
  ].freeze

  def initialize(session)
    @session = session
  end

  def compact!
    # Advisory lock prevents concurrent compaction on same session
    @session.with_advisory_lock("compaction_#{@session.id}") do
      messages = @session.messages.where(compacted: false).order(:created_at).to_a
      return if messages.size <= PRESERVE_RECENT

      to_compact = messages[0...-PRESERVE_RECENT]
      preserved_facts = extract_preserved_content(to_compact)

      summary = RubyLLM.chat(model: SUMMARY_MODEL)
                       .with_temperature(0.1)
                       .ask(<<~PROMPT)
        Summarize this conversation segment concisely. Preserve:
        - Key decisions and their rationale
        - Specific facts, numbers, file paths, error messages
        - User preferences and instructions
        - Tool call results that informed decisions
        Discard greetings, acknowledgments, and verbose explanations.

        #{preserved_facts}

        Conversation to summarize:
        #{to_compact.map { |m| "[#{m.role}] #{m.content.to_s.truncate(500)}" }.join("\n")}
      PROMPT

      ActiveRecord::Base.transaction do
        to_compact.each { |m| m.update!(compacted: true) }
        @session.update!(summary: summary.content)
      end
    end
  end

  private

  def extract_preserved_content(messages)
    preserved = []
    messages.each do |msg|
      PROTECTED_PATTERNS.each do |pattern|
        matches = msg.content.to_s.scan(pattern)
        preserved.concat(matches) if matches.any?
      end
    end
    preserved.any? ? "MUST PRESERVE:\n#{preserved.join("\n")}\n\n" : ""
  end
end
```

### Database Archival

Sessions inactive >7 days are archived by `ArchiveStaleSessionsJob` (GoodJob cron). The summary + key facts + embedding are stored in `conversation_archives` for Layer 3 memory retrieval. Messages are retained for 30 days after archival, then pruned.

---

## 9. Streaming Architecture

Falcon's fiber-based concurrency is the critical enabler. Each LLM API call blocks for 5-60 seconds, but with Falcon, that blocking call yields its fiber, allowing thousands of concurrent streaming connections in a single process.

### Streaming Flow

```
User sends message (REST POST)
  │
  ▼
MessagesController enqueues ChatStreamJob (GoodJob :llm queue)
  │
  ▼ (GoodJob worker process — NOT Falcon)
ChatStreamJob calls AgentRuntime.run(message) with streaming block
  │
  ├─ Each token chunk → ActionCable.server.broadcast via Valkey pub/sub
  │     → Falcon receives from Valkey → pushes to WebSocket client
  │
  ├─ On complete → broadcast { type: "complete", content: full_text, message_id: ... }
  │
  └─ On error → broadcast { type: "error", message: "..." }
```

### Key Design Points

- **LLM calls run in GoodJob workers** (separate process), not in Falcon. This avoids blocking the fiber reactor and provides crash recovery.
- **ActionCable cross-process**: `ActionCable.server.broadcast` works from GoodJob because it publishes to Valkey; Falcon subscribes and pushes to WebSocket clients.
- **SessionChannel is output-only**: Messages are sent via REST POST, not `ActionCable.receive`. The channel only subscribes to a session's broadcast stream.
- **Token events**: `{ type: "token", delta: "...", message_id: "..." }` — one per chunk.
- **Complete event includes full content**: Prevents stale-closure bugs in frontend — the client can use `event.content` directly instead of relying on accumulated state.
- **Falcon config**: `isolation_level = :fiber` in production, Redis adapter for ActionCable (Valkey-compatible).

> **Initial implementation:** [RFC 002](../rfc-open/2026-03-29-simple-chat-conversation.md) implements the full streaming flow with `SimpleChatService` (no tools/memory). The `complete` event always includes `content` to fix the frontend stale-closure bug identified during RFC design.

### Parallel Agent Execution

For fan-out to multiple agents (e.g., orchestrator querying specialists), Falcon's fibers enable true concurrent execution. A `ParallelAgentExecutor` service uses `Async::Semaphore` (max 5 concurrent) to dispatch multiple `AgentRuntime.run` calls as fibers, resolving sessions per-agent and collecting results. This is deferred until multi-agent routing ships.

---

## 10. Embedding & Background Processing

Embeddings are generated asynchronously to avoid blocking the request cycle. See [04 §8](./04-billing-and-operations.md#8-goodjob-configuration) for the full `GenerateEmbeddingJob` implementation with allowlisting and concurrency controls.

### Memory Extraction

Automatically extracts memorable facts from conversations:

**Performance note**: In production, memory extraction should be batched — triggered on session idle (5min of inactivity) or every N messages, not per-response. The per-response pattern shown here is illustrative.

```ruby
# app/jobs/memory_extraction_job.rb
class MemoryExtractionJob < ApplicationJob
  queue_as :default

  EXTRACTION_PROMPT = <<~PROMPT
    Analyze this assistant response and extract any facts about the user that are
    worth remembering long-term. Return a JSON array of memories, each with:
    - "content": the fact to remember (concise, single sentence)
    - "category": one of "preference", "fact", "instruction", "context"
    - "importance": 1-10 score

    Only extract genuinely memorable facts. Return [] if nothing is worth storing.
    Response to analyze:
  PROMPT

  def perform(session_id, response_content, user_id:)
    session = Session.find(session_id)
    return if response_content.blank? || response_content.length < 50

    result = RubyLLM.chat(model: "gpt-4o-mini")
                    .with_temperature(0.1)
                    .with_schema({ type: "object", properties: {
                      memories: { type: "array", items: {
                        type: "object",
                        properties: {
                          content: { type: "string" },
                          category: { type: "string", enum: %w[preference fact instruction context] },
                          importance: { type: "integer", minimum: 1, maximum: 10 }
                        }, required: %w[content category importance]
                      }}
                    }, required: ["memories"] })
                    .ask("#{EXTRACTION_PROMPT}\n#{response_content}")

    memories = result.content["memories"]
    memories.each do |mem|
      next if mem["importance"] < 6

      # Deduplicate via semantic similarity
      embedding = RubyLLM.embed(mem["content"]).vectors
      existing = session.user.memory_entries.active
        .nearest_neighbors(:embedding, embedding, distance: "cosine")
        .first
      # Threshold requires empirical validation — 0.20 is a conservative starting point
      next if existing && existing.neighbor_distance < 0.20

      session.user.memory_entries.create!(
        content: mem["content"],
        category: mem["category"],
        importance: mem["importance"],
        session: session,
        agent: (session.agent.memory_isolation == "shared" ? nil : session.agent),
        source: "agent"
      )
    end
  end
end
```

---

## 11. Complete Request Flow

```
Request arrives (Web ActionCable / Telegram webhook / API POST)
  │
  ▼
UserRlsMiddleware
  │ SET app.current_user_id = '...'
  │ (all subsequent queries are RLS-filtered)
  ▼
SessionResolver.resolve(user:, agent_slug:, channel:)
  │ Agent is a DB row, not a class
  ▼
BudgetEnforcer.check!(user:)
  │
  ▼
ChatStreamJob.perform_later(session_id, user_id, message)
  │ (GoodJob picks up from Postgres, sets RLS in around_perform)
  ▼
AgentRuntime.new(session:, user:)
  │
  ├─ LlmContextBuilder.build(user:)
  │    └─ RubyLLM.context { |c| c.openai_api_key = user's BYOK key }
  │
  ├─ resolve_tools
  │    ├─ ToolRegistry.build(agent.tool_names, ...)    # Local tools
  │    ├─ McpClientManager.tools_for(user:)            # MCP tools
  │    └─ HandoffTool (if targets exist, depth < 3)    # Routing
  │
  ├─ Agent#resolved_instructions  # soul + identity + constraints + context
  │
  ├─ MemoryRetrievalService.build_context
  │    ├─ Layer 2: Memories (within token budget, by importance)
  │    ├─ Layer 3: Relevant archived conversations (top 5)
  │    ├─ Layer 5: Synthesized user profile
  │    └─ Daily logs (today + yesterday)
  │
  ├─ CompactionService.compact! (if context > 75%)
  │
  ├─ ctx.chat(model: agent.model_id)
  │    .with_tools(...)
  │    .with_instructions(...)
  │    .with_params(**agent.thinking_config)
  │
  ▼ ── ReAct Loop (inside ruby_llm) ──
  │ LLM → tool call → execute → feed result → loop
  │    ├─ NotesTool, MemoryTool, VaultTool (local execution)
  │    ├─ HandoffTool → spawns new AgentRuntime (depth + 1)
  │    ├─ MCP tools (external servers)
  │    └─ Built-in tools via Responses API (web search, code interpreter)
  │
  ▼ ── Streaming ──
  │ Each chunk → ActionCable broadcast → WebSocket → client
  │ Each chunk → TelegramAdapter.send (batched) → Telegram API
  │
  ▼ ── Post-processing ──
  ├─ UsageRecorder.record(message:, session:, user:)
  ├─ MemoryExtractionJob.perform_later (async)
  ├─ GenerateEmbeddingJob for new notes/memories (async)
  └─ Update session.total_tokens + last_activity_at
```

---

## 12. Key Architectural Decisions

**Why a flat message list, not a tree.** Claude Code's architecture proves that a single flat conversation history with one sub-agent branch at a time outperforms complex threading. Trees create ambiguity about which context matters; flat lists are debuggable and predictable.

**Why token-budgeted memory retrieval, not dump-all.** Memory retrieval respects the 10% token budget allocation from `MemoryRetrievalService`. Memories are ordered by importance + recency, and injected until the budget is exhausted. This avoids unbounded cost growth as users accumulate memories.

**Why HNSW over IVFFlat.** The data is constantly growing (new messages, memories, vault documents every session). HNSW handles inserts without index rebuilds and delivers ~1.5ms query latency with 95%+ recall at default settings. IVFFlat requires periodic retraining.

**Why Falcon over Puma.** A single Falcon process handles thousands of concurrent LLM streaming connections via fibers, each consuming ~4KB of memory. Puma would need 25+ threads to match, each consuming megabytes and a database connection.

**Why both ruby_llm providers.** Standard providers give multi-model flexibility (Anthropic for reasoning, Gemini for cost). Responses API gives server-side state, built-in tools, and automatic compaction for OpenAI models. Same `chat.ask` API means agents can switch providers without code changes.

**Why handoff depth limit of 3.** Prevents infinite A↔B handoff cycles and unbounded stack/connection consumption. Each handoff creates a new AgentRuntime synchronously — depth 3 means at most 4 concurrent runtimes.

---

## 13. Open Questions

1. **Session quality & robustness** — The most complex subsystem. Needs detailed design for: smart compaction algorithms (what to keep vs summarize), session replay for debugging, long message summarization before sending to LLM, message searchability across sessions, memory promotion heuristics. Priority for next design phase.
2. **Compaction concurrency** — Advisory lock prevents concurrent compaction on same session, but rapid back-and-forth near the threshold needs testing.
3. **Provider failover** — LLM router should fall back to OpenRouter when primary provider fails. Not yet implemented in AgentRuntime.
4. **Handoff cycle detection** — Currently relies on `handoff_targets` not containing cycles. Should validate acyclicity at agent save time (topological sort or DFS).
5. **Session continuity verification** — Verify that ruby_llm's `acts_as_chat` auto-loads persisted messages into the chat context. If not, explicit message injection is needed.
