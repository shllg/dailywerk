# Agentic chat on Rails 8: a full implementation architecture

**The most effective architecture for a multi-agent chat system on Rails 8 combines ruby_llm's provider-agnostic agent framework with Falcon's fiber-based concurrency, PostgreSQL + pgvector for persistent memory and semantic search, and a carefully layered session/channel abstraction.** This design draws directly from production patterns in Claude Code, OpenAI Codex, and ChatGPT — specifically the single-threaded ReAct loop, file-based memory, and sliding-window compaction — adapted to Ruby idioms. What follows is a complete blueprint: database schema, class hierarchy, routing logic, tool system, memory architecture, and compaction strategies, all grounded in the actual APIs of ruby_llm (v1.14+) and ruby_llm-responses_api (v0.5+).

---

## The foundation: ruby_llm's architecture and what it gives you for free

ruby_llm provides three critical primitives for this system. First, `RubyLLM::Chat` manages a conversation as a flat message array with fluent configuration — `.with_tool(Weather).with_instructions("...").with_temperature(0.2)` — and handles the tool-execution loop internally: when the LLM returns a tool call, ruby_llm executes the Ruby `Tool#execute` method, feeds the result back, and loops until the model produces text. Second, `RubyLLM::Agent` wraps Chat in a class-based DSL with `model`, `instructions`, `tools`, and `temperature` macros, plus Rails persistence via `chat_model`. Third, the ActiveRecord integration (`acts_as_chat`, `acts_as_message`, `acts_as_tool_call`) persists conversations with **streaming-first design** — creating empty assistant messages early for DOM targeting, then updating them as chunks arrive.

The ruby_llm-responses_api gem adds the `:openai_responses` provider, which maps the same `chat.ask` API to OpenAI's `/v1/responses` endpoint. The key wins: **server-side conversation state** via `previous_response_id` (only the new message is sent each turn, not the full history), **built-in hosted tools** (web search, code interpreter, file search, shell), **automatic server-side compaction** when tokens exceed a threshold, and **WebSocket transport** for sub-100ms latency in rapid tool-call loops. A single `response_id` column on the messages table enables session resumption after restarts.

The dual-provider strategy is central to this architecture: use `:openai_responses` for OpenAI models to get server-side state and built-in tools, and standard ruby_llm providers for Anthropic, Gemini, and others where you need multi-provider flexibility.

---

## Database schema: the complete migration set

The schema extends ruby_llm's defaults with purpose-built tables for multi-agent routing, multi-session channels, memory, and the User Vault. **pgvector powers both memory retrieval and vault search through HNSW indexes**, chosen over IVFFlat because the data is dynamic (new memories and documents arrive constantly) and HNSW handles inserts without rebuilds.

```ruby
# db/migrate/001_enable_extensions.rb
class EnableExtensions < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pgcrypto"
    enable_extension "vector"
  end
end

# db/migrate/002_create_core_tables.rb
class CreateCoreTables < ActiveRecord::Migration[8.0]
  def change
    # ── Agents (definitions, not instances) ──
    create_table :agents, id: :uuid do |t|
      t.string   :slug,         null: false, index: { unique: true }
      t.string   :name,         null: false
      t.string   :model_id,     null: false, default: "claude-sonnet-4-6"
      t.string   :provider                    # nil = auto-detect
      t.text     :instructions
      t.string   :instructions_path           # ERB prompt file path
      t.jsonb    :tool_names,    default: []  # ["notes", "memory", "vault_search"]
      t.jsonb    :handoff_targets, default: [] # ["research_agent", "code_agent"]
      t.float    :temperature,   default: 0.7
      t.jsonb    :params,        default: {}  # max_tokens, thinking, etc.
      t.jsonb    :metadata,      default: {}
      t.boolean  :active,        default: true
      t.timestamps
    end

    # ── Channels (Telegram, Web, API, etc.) ──
    create_table :channels, id: :uuid do |t|
      t.string   :channel_type,  null: false  # "telegram", "web", "api", "slack"
      t.string   :external_id                 # telegram chat_id, slack channel_id
      t.jsonb    :config,        default: {}  # webhook_url, bot_token_ref, etc.
      t.references :user,        type: :uuid, foreign_key: true
      t.timestamps
      t.index [:channel_type, :external_id], unique: true
    end

    # ── Sessions (one per agent × channel combination) ──
    create_table :sessions, id: :uuid do |t|
      t.references :agent,   type: :uuid, null: false, foreign_key: true
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.references :user,    type: :uuid, foreign_key: true
      t.string     :model_id
      t.string     :provider
      t.string     :status,       default: "active" # active, archived, compacted
      t.text       :summary                          # compacted conversation summary
      t.integer    :total_tokens, default: 0
      t.jsonb      :context_data, default: {}        # sliding window metadata
      t.timestamps
      t.index [:agent_id, :channel_id], unique: true,
              where: "status = 'active'"
    end

    # ── Messages ──
    create_table :messages, id: :uuid do |t|
      t.references :session,  type: :uuid, null: false, foreign_key: true
      t.string     :role,     null: false   # user, assistant, system, tool
      t.text       :content
      t.text       :content_raw              # provider-specific Content::Raw
      t.string     :response_id              # OpenAI Responses API chaining
      t.string     :agent_slug               # which agent produced this message
      t.integer    :input_tokens
      t.integer    :output_tokens
      t.integer    :cached_tokens
      t.text       :thinking_text
      t.text       :thinking_signature
      t.integer    :thinking_tokens
      t.boolean    :compacted, default: false # marked as summarized
      t.integer    :importance, default: 5    # 1-10 importance score
      t.timestamps
      t.index [:session_id, :created_at]
      t.index [:session_id, :compacted]
    end

    # ── Tool Calls ──
    create_table :tool_calls, id: :uuid do |t|
      t.references :message, type: :uuid, null: false, foreign_key: true
      t.string     :tool_call_id
      t.string     :name
      t.jsonb      :arguments, default: {}
      t.text       :result
      t.string     :status, default: "pending" # pending, success, error
      t.integer    :duration_ms
      t.timestamps
    end

    # ── Memories (explicit long-term storage) ──
    create_table :memories, id: :uuid do |t|
      t.references :user,    type: :uuid, null: false, foreign_key: true
      t.references :session, type: :uuid, foreign_key: true  # source session
      t.string     :category, default: "general"  # preference, fact, instruction
      t.text       :content,  null: false
      t.integer    :importance, default: 5
      t.integer    :access_count, default: 0
      t.datetime   :last_accessed_at
      t.boolean    :active, default: true
      t.vector     :embedding, limit: 1536  # text-embedding-3-small
      t.timestamps
      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
      t.index [:user_id, :category]
      t.index [:user_id, :active, :importance]
    end

    # ── Notes (persistent agent note-taking) ──
    create_table :notes, id: :uuid do |t|
      t.references :user,    type: :uuid, null: false, foreign_key: true
      t.references :session, type: :uuid, foreign_key: true
      t.string     :title
      t.text       :content,  null: false
      t.string     :tags,     array: true, default: []
      t.jsonb      :metadata, default: {}
      t.vector     :embedding, limit: 1536
      t.timestamps
      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
      t.index [:user_id, :created_at]
      t.index :tags, using: :gin
    end

    # ── User Vault (Obsidian-style knowledge base) ──
    create_table :vault_documents, id: :uuid do |t|
      t.references :user,    type: :uuid, null: false, foreign_key: true
      t.string     :title,   null: false
      t.string     :path,    null: false  # "projects/rails-chat/architecture.md"
      t.text       :content,  null: false  # raw markdown
      t.string     :tags,     array: true, default: []
      t.jsonb      :frontmatter, default: {}  # YAML frontmatter as JSON
      t.vector     :embedding, limit: 1536
      t.tsvector   :search_vector             # full-text search
      t.timestamps
      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
      t.index :search_vector, using: :gin
      t.index [:user_id, :path], unique: true
      t.index :tags, using: :gin
    end

    # ── Vault Links (bidirectional backlinks) ──
    create_table :vault_links, id: :uuid do |t|
      t.references :source, type: :uuid, null: false,
                   foreign_key: { to_table: :vault_documents }
      t.references :target, type: :uuid, null: false,
                   foreign_key: { to_table: :vault_documents }
      t.string     :link_type, default: "reference" # reference, embed, tag
      t.text       :context    # surrounding text snippet
      t.timestamps
      t.index [:source_id, :target_id, :link_type], unique: true
      t.index :target_id  # fast backlink lookups
    end

    # ── Conversation Archives (cold storage) ──
    create_table :conversation_archives, id: :uuid do |t|
      t.references :session, type: :uuid, null: false, foreign_key: true
      t.text       :summary
      t.jsonb      :key_facts,   default: []
      t.integer    :message_count
      t.integer    :total_tokens
      t.vector     :embedding, limit: 1536
      t.daterange  :date_range
      t.timestamps
      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
    end
  end
end
```

---

## Ruby class hierarchy: agents, sessions, and the orchestration layer

The architecture separates **agent definitions** (what an agent can do) from **agent instances** (a running agent within a session). This mirrors how ruby_llm's `Agent` class wraps `Chat` — but adds routing, handoffs, and multi-session support.

```ruby
# app/models/agent.rb — Database-backed agent definition
class Agent < ApplicationRecord
  has_many :sessions, dependent: :destroy
  validates :slug, presence: true, uniqueness: true
  validates :model_id, presence: true

  # Resolve tool classes from stored names
  def tool_classes
    tool_names.filter_map { |name| ToolRegistry.resolve(name) }
  end

  # Resolve handoff agent instances
  def handoff_agents
    Agent.where(slug: handoff_targets, active: true)
  end
end
```

```ruby
# app/models/session.rb — Conversation session (agent × channel)
class Session < ApplicationRecord
  acts_as_chat  # ruby_llm ActiveRecord integration

  belongs_to :agent
  belongs_to :channel
  belongs_to :user, optional: true
  has_many   :messages, dependent: :destroy
  has_many   :notes,    dependent: :nullify
  has_many   :memories, dependent: :nullify

  scope :active, -> { where(status: "active") }

  def context_window_usage
    total_tokens.to_f / context_window_size
  end

  def context_window_size
    RubyLLM.models.find(model_id || agent.model_id).context_window
  end
end
```

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  acts_as_message

  belongs_to :session
  has_many   :tool_calls, dependent: :destroy

  scope :uncompacted,  -> { where(compacted: false) }
  scope :recent_first, -> { order(created_at: :desc) }
  scope :for_context,  -> { where(compacted: false).order(:created_at) }

  after_create_commit -> {
    broadcast_append_to "session_#{session_id}",
      partial: "messages/message", locals: { message: self }
  }
end
```

```ruby
# app/models/channel.rb — Channel abstraction layer
class Channel < ApplicationRecord
  belongs_to :user, optional: true
  has_many   :sessions, dependent: :destroy

  validates :channel_type, presence: true,
    inclusion: { in: %w[web telegram api slack discord] }
  validates :external_id, uniqueness: { scope: :channel_type },
    allow_nil: true

  def adapter
    ChannelAdapterRegistry.resolve(channel_type, config)
  end
end
```

---

## The agent runtime: ReAct loop with handoffs

The core runtime is a single-threaded ReAct loop — the same pattern Claude Code and Codex use — wrapped in a service object that manages context, tools, and inter-agent routing. **The critical insight from production systems is that radical simplicity in the core loop outperforms complex multi-agent swarms.**

```ruby
# app/services/agent_runtime.rb
class AgentRuntime
  MAX_TOOL_ITERATIONS = 25
  COMPACTION_THRESHOLD = 0.75  # trigger at 75% of context window

  def initialize(session:, user:)
    @session = session
    @agent   = session.agent
    @user    = user
    @chat    = build_chat
  end

  # ── Main entry point ──
  def run(user_message, &stream_block)
    # 1. Check context budget, compact if needed
    compact_if_needed!

    # 2. Inject memories and context
    inject_memory_context

    # 3. Execute the agent loop
    response = @chat.ask(user_message, &stream_block)

    # 4. Post-processing: extract memories, update token counts
    postprocess(response)

    response
  end

  private

  def build_chat
    chat = if @agent.provider == "openai_responses"
      RubyLLM.chat(model: @agent.model_id, provider: :openai_responses)
    else
      RubyLLM.chat(model: @agent.model_id, provider: @agent.provider&.to_sym)
    end

    chat.with_instructions(load_instructions)
        .with_tools(*@agent.tool_classes, *routing_tools)
        .with_temperature(@agent.temperature)
        .with_params(**@agent.params.symbolize_keys)

    # Wire up event handlers
    chat.on_tool_call  { |tc| record_tool_call(tc) }
    chat.on_tool_result { |r| record_tool_result(r) }
    chat.on_end_message { |msg| update_token_counts(msg) }

    # Enable server-side compaction for Responses API
    if @agent.provider == "openai_responses"
      chat.with_params(
        context_management: [{ type: "compaction", compact_threshold: 150_000 }]
      )
    end

    chat
  end

  def load_instructions
    base = @agent.instructions_path ?
      ERB.new(File.read(Rails.root.join("app/prompts", @agent.instructions_path))).result(binding) :
      @agent.instructions

    # Append current user context
    <<~PROMPT
      #{base}

      ## Current Context
      User: #{@user.name} (ID: #{@user.id})
      Channel: #{@session.channel.channel_type}
      Session ID: #{@session.id}
      Available agents for handoff: #{@agent.handoff_targets.join(', ')}
    PROMPT
  end

  def routing_tools
    return [] if @agent.handoff_targets.empty?
    [HandoffTool.new(agent: @agent, session: @session, user: @user)]
  end

  def inject_memory_context
    memories = Memory.for_user(@user)
                     .active
                     .most_relevant_to(@session)
                     .limit(20)
    return if memories.empty?

    memory_block = memories.map { |m| "- #{m.content}" }.join("\n")
    @chat.add_message(role: :system, content: <<~MEM)
      ## User Memories
      #{memory_block}
    MEM
  end

  def compact_if_needed!
    return if @session.context_window_usage < COMPACTION_THRESHOLD
    CompactionService.new(@session).compact!
  end

  def postprocess(response)
    MemoryExtractionJob.perform_later(@session.id, response.content)
    @session.update!(
      total_tokens: @session.total_tokens +
        response.input_tokens.to_i + response.output_tokens.to_i
    )
  end
end
```

---

## Multi-agent routing: hierarchical orchestration with peer handoffs

The system supports both coordination patterns through a unified mechanism. **Hierarchical routing** uses an orchestrator agent that dispatches to sub-agents via tool calls. **Peer-to-peer routing** uses a `HandoffTool` that any agent can invoke to transfer control to another agent — directly inspired by OpenAI's Agents SDK handoff pattern.

```ruby
# app/tools/handoff_tool.rb
class HandoffTool < RubyLLM::Tool
  description "Transfer this conversation to another specialized agent. " \
              "Use when the user's request falls outside your expertise."

  param :target_agent, desc: "The slug of the agent to hand off to"
  param :reason, desc: "Why you are handing off (passed to the next agent)"
  param :context_summary, desc: "Key context the next agent needs to know"

  def initialize(agent:, session:, user:)
    @source_agent = agent
    @session = session
    @user = user
  end

  def execute(target_agent:, reason:, context_summary:)
    target = Agent.find_by(slug: target_agent, active: true)
    return { error: "Unknown agent '#{target_agent}'. Available: #{@source_agent.handoff_targets.join(', ')}" } unless target
    return { error: "Cannot hand off to '#{target_agent}'" } unless target.slug.in?(@source_agent.handoff_targets)

    # Record the handoff in the session
    @session.messages.create!(
      role: "system",
      content: "--- Handoff: #{@source_agent.slug} → #{target.slug} ---\nReason: #{reason}\nContext: #{context_summary}",
      agent_slug: @source_agent.slug
    )

    # Build a new runtime for the target agent and re-run
    target_session = Session.find_or_create_by!(
      agent: target, channel: @session.channel, status: "active"
    ) { |s| s.user = @user }

    runtime = AgentRuntime.new(session: target_session, user: @user)
    response = runtime.run(context_summary)

    # Return the target agent's response as the tool result
    { agent: target.slug, response: response.content }
  end
end
```

```ruby
# app/agents/orchestrator_agent.rb — Hierarchical orchestrator
class OrchestratorAgent < RubyLLM::Agent
  model "claude-sonnet-4-6"
  instructions <<~INST
    You are a routing orchestrator. Analyze the user's request and either:
    1. Answer directly if it's a simple greeting or meta-question
    2. Use the handoff tool to route to the appropriate specialist:
       - "research_agent" for web research, fact-finding
       - "code_agent" for programming tasks
       - "writing_agent" for content creation
       - "memory_agent" for knowledge management, notes, vault operations
    Always provide a context_summary so the specialist has full context.
  INST
  tools HandoffTool
  temperature 0.3
end

# app/agents/research_agent.rb — Specialist with its own tools
class ResearchAgent < RubyLLM::Agent
  model "gpt-4o"
  instructions "app/prompts/research_agent/instructions.txt.erb"
  tools WebSearchTool, NotesTool, MemoryTool
  temperature 0.5
end
```

The **agent registry** maps slugs to runtime configurations:

```ruby
# app/services/agent_registry.rb
class AgentRegistry
  DEFINITIONS = {
    "orchestrator" => { class: OrchestratorAgent, model: "claude-sonnet-4-6",
                        handoffs: %w[research code writing memory] },
    "research"     => { class: ResearchAgent, model: "gpt-4o",
                        handoffs: %w[orchestrator code] },
    "code"         => { class: CodeAgent, model: "claude-sonnet-4-6",
                        handoffs: %w[orchestrator research] },
    "writing"      => { class: WritingAgent, model: "gpt-4o",
                        handoffs: %w[orchestrator research] },
    "memory"       => { class: MemoryAgent, model: "gpt-4o-mini",
                        handoffs: %w[orchestrator] }
  }.freeze

  def self.resolve(slug)
    DEFINITIONS[slug] || raise(AgentNotFoundError, "Unknown agent: #{slug}")
  end
end
```

---

## Multi-session channel abstraction

The session model enforces **one active session per agent-channel pair** with isolated conversation threads. A user talking to the same agent on Telegram and Web UI gets two independent conversation histories — fulfilling the requirement that messages are never synced between channels.

```ruby
# app/services/channel_adapter_registry.rb
module ChannelAdapterRegistry
  ADAPTERS = {
    "web"      => WebChannelAdapter,
    "telegram" => TelegramChannelAdapter,
    "api"      => ApiChannelAdapter,
    "slack"    => SlackChannelAdapter
  }.freeze

  def self.resolve(channel_type, config = {})
    ADAPTERS.fetch(channel_type).new(config)
  end
end

# app/adapters/base_channel_adapter.rb
class BaseChannelAdapter
  def initialize(config); @config = config; end
  def send_message(session, content) = raise NotImplementedError
  def send_streaming_chunk(session, chunk) = raise NotImplementedError
  def format_tool_result(result) = result.to_s
end

# app/adapters/web_channel_adapter.rb
class WebChannelAdapter < BaseChannelAdapter
  def send_streaming_chunk(session, chunk)
    ActionCable.server.broadcast(
      "session_#{session.id}",
      { type: "token", content: chunk.content, agent: chunk.model_id }
    )
  end
end

# app/adapters/telegram_channel_adapter.rb
class TelegramChannelAdapter < BaseChannelAdapter
  def send_message(session, content)
    Telegram::Bot::Client.new(@config["bot_token"]).api.send_message(
      chat_id: session.channel.external_id,
      text: content, parse_mode: "Markdown"
    )
  end
end
```

The **session resolver** finds or creates the right session:

```ruby
# app/services/session_resolver.rb
class SessionResolver
  def self.resolve(user:, agent_slug:, channel_type:, external_id: nil)
    channel = Channel.find_or_create_by!(
      user: user, channel_type: channel_type, external_id: external_id
    )
    agent = Agent.find_by!(slug: agent_slug, active: true)

    Session.find_or_create_by!(agent: agent, channel: channel, status: "active") do |s|
      s.user    = user
      s.model_id = agent.model_id
      s.provider = agent.provider
    end
  end
end
```

---

## Tool system: Notes, Memory, and User Vault

Each tool follows ruby_llm's `Tool` base class pattern. **Tools receive the current user and session as constructor arguments**, enabling scoped data access without global state.

```ruby
# app/tools/notes_tool.rb
class NotesTool < RubyLLM::Tool
  description "Create, search, and manage persistent notes for the user. " \
              "Use for capturing ideas, task lists, meeting notes, and reference material."

  params do
    string :action, description: "create, search, update, list, delete", enum: %w[create search update list delete]
    string :title, description: "Note title (for create/update)"
    string :content, description: "Note content in markdown (for create/update)"
    string :query, description: "Search query (for search)"
    string :note_id, description: "Note UUID (for update/delete)"
    array  :tags, of: :string, description: "Tags to apply"
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
      GenerateEmbeddingJob.perform_later("Note", note.id)
      { id: note.id, title: note.title, status: "created" }
    when "search"
      results = @user.notes
        .nearest_neighbors(:embedding, RubyLLM.embed(params[:query]).vectors, distance: "cosine")
        .limit(5)
      results.map { |n| { id: n.id, title: n.title, content: n.content.truncate(500), distance: n.neighbor_distance } }
    when "list"
      @user.notes.order(updated_at: :desc).limit(20)
           .pluck(:id, :title, :tags, :updated_at)
           .map { |id, title, tags, at| { id:, title:, tags:, updated_at: at.iso8601 } }
    when "update"
      note = @user.notes.find(params[:note_id])
      note.update!(params.slice(:title, :content, :tags).compact)
      GenerateEmbeddingJob.perform_later("Note", note.id)
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

```ruby
# app/tools/memory_tool.rb
class MemoryTool < RubyLLM::Tool
  description "Store and retrieve explicit long-term memories about the user. " \
              "Use for preferences, facts, instructions the user wants remembered across sessions."

  params do
    string :action, enum: %w[store recall forget list]
    string :content, description: "Memory content to store"
    string :category, description: "Memory category: preference, fact, instruction, context"
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
      mem = @user.memories.create!(
        content: params[:content],
        category: params[:category] || "general",
        importance: params[:importance] || 5,
        session: @session
      )
      GenerateEmbeddingJob.perform_later("Memory", mem.id)
      { id: mem.id, status: "stored" }
    when "recall"
      query_embedding = RubyLLM.embed(params[:query]).vectors
      results = @user.memories.active
        .nearest_neighbors(:embedding, query_embedding, distance: "cosine")
        .limit(10)
      # Apply multi-signal scoring
      scored = results.map do |m|
        recency = Math.exp(-0.005 * (Time.current - m.updated_at).to_f / 3600)
        importance_norm = m.importance / 10.0
        relevance = 1.0 - m.neighbor_distance
        score = 0.3 * recency + 0.3 * importance_norm + 0.4 * relevance
        { id: m.id, content: m.content, category: m.category, score: score.round(3) }
      end
      scored.sort_by { |s| -s[:score] }.first(5)
    when "forget"
      @user.memories.find(params[:memory_id]).update!(active: false)
      { status: "deactivated" }
    when "list"
      @user.memories.active.order(importance: :desc, updated_at: :desc).limit(20)
           .map { |m| { id: m.id, content: m.content.truncate(200), category: m.category, importance: m.importance } }
    end
  end
end
```

```ruby
# app/tools/vault_tool.rb — Obsidian-style interconnected knowledge base
class VaultTool < RubyLLM::Tool
  description "Manage the user's personal knowledge vault — an Obsidian-style system of " \
              "interconnected markdown documents with backlinks, tags, and graph relationships."

  params do
    string :action, enum: %w[create read update search backlinks graph tag_search]
    string :path,    description: "Document path like 'projects/my-app/notes.md'"
    string :title,   description: "Document title"
    string :content, description: "Markdown content (supports [[backlinks]] and #tags)"
    string :query,   description: "Search query (semantic + full-text)"
    array  :tags,    of: :string
    string :document_id, description: "Document UUID"
  end

  def initialize(user:, session:)
    @user = user; @session = session
  end

  def execute(action:, **params)
    case action
    when "create"
      doc = create_document(params)
      { id: doc.id, path: doc.path, backlinks_created: extract_and_link(doc) }
    when "read"
      doc = find_doc(params)
      backlinks = VaultLink.where(target: doc).includes(:source).map { |l| l.source.path }
      { id: doc.id, path: doc.path, content: doc.content, tags: doc.tags,
        frontmatter: doc.frontmatter, backlinks: backlinks }
    when "search"
      hybrid_search(params[:query])
    when "backlinks"
      doc = find_doc(params)
      VaultLink.where(target: doc).includes(:source).map do |link|
        { source_path: link.source.path, context: link.context, type: link.link_type }
      end
    when "graph"
      build_local_graph(find_doc(params), depth: 2)
    when "tag_search"
      @user.vault_documents.where("tags @> ARRAY[?]::varchar[]", params[:tags])
           .limit(20).map { |d| { id: d.id, path: d.path, title: d.title, tags: d.tags } }
    when "update"
      doc = find_doc(params)
      doc.update!(params.slice(:content, :title, :tags).compact)
      VaultLink.where(source: doc).delete_all
      extract_and_link(doc)
      GenerateEmbeddingJob.perform_later("VaultDocument", doc.id)
      { id: doc.id, status: "updated" }
    end
  end

  private

  def create_document(params)
    frontmatter = extract_frontmatter(params[:content])
    tags = (params[:tags] || []) + extract_tags(params[:content])
    doc = @user.vault_documents.create!(
      title: params[:title], path: params[:path],
      content: params[:content], tags: tags.uniq,
      frontmatter: frontmatter
    )
    GenerateEmbeddingJob.perform_later("VaultDocument", doc.id)
    doc
  end

  def extract_and_link(doc)
    links_created = 0
    # Extract [[backlinks]]
    doc.content.scan(/\[\[([^\]]+)\]\]/).flatten.each do |ref|
      target = @user.vault_documents.find_by("title ILIKE ? OR path ILIKE ?", ref, "%#{ref}%")
      next unless target
      context = doc.content[/(.{0,100}\[\[#{Regexp.escape(ref)}\]\].{0,100})/m, 1]
      VaultLink.find_or_create_by!(source: doc, target: target, link_type: "reference") do |l|
        l.context = context
      end
      links_created += 1
    end
    links_created
  end

  def extract_tags(content)
    content.scan(/#([\w\/\-]+)/).flatten
  end

  def extract_frontmatter(content)
    return {} unless content.start_with?("---")
    yaml_block = content.match(/\A---\n(.+?)\n---/m)&.captures&.first
    yaml_block ? YAML.safe_load(yaml_block) : {}
  rescue Psych::SyntaxError
    {}
  end

  def hybrid_search(query)
    # Combine semantic search + full-text search via RRF
    embedding = RubyLLM.embed(query).vectors
    semantic = @user.vault_documents
      .nearest_neighbors(:embedding, embedding, distance: "cosine").limit(10)
    fulltext = @user.vault_documents
      .where("search_vector @@ plainto_tsquery('english', ?)", query).limit(10)

    # Reciprocal Rank Fusion
    rrf_scores = Hash.new(0.0)
    semantic.each_with_index { |doc, i| rrf_scores[doc.id] += 1.0 / (60 + i) }
    fulltext.each_with_index { |doc, i| rrf_scores[doc.id] += 1.0 / (60 + i) }

    doc_ids = rrf_scores.sort_by { |_, s| -s }.first(5).map(&:first)
    VaultDocument.where(id: doc_ids).index_by(&:id).values_at(*doc_ids).compact
      .map { |d| { id: d.id, path: d.path, title: d.title, content: d.content.truncate(300), tags: d.tags } }
  end

  def build_local_graph(doc, depth: 2)
    visited = Set.new
    graph = { nodes: [], edges: [] }
    traverse(doc, graph, visited, depth)
    graph
  end

  def traverse(doc, graph, visited, remaining_depth)
    return if visited.include?(doc.id) || remaining_depth < 0
    visited.add(doc.id)
    graph[:nodes] << { id: doc.id, title: doc.title, path: doc.path, tags: doc.tags }

    VaultLink.where(source: doc).or(VaultLink.where(target: doc)).includes(:source, :target).each do |link|
      neighbor = link.source_id == doc.id ? link.target : link.source
      graph[:edges] << { from: link.source_id, to: link.target_id, type: link.link_type }
      traverse(neighbor, graph, visited, remaining_depth - 1)
    end
  end

  def find_doc(params)
    if params[:document_id]
      @user.vault_documents.find(params[:document_id])
    else
      @user.vault_documents.find_by!(path: params[:path])
    end
  end
end
```

The **tool registry** maps string names to classes and handles dependency injection:

```ruby
# app/services/tool_registry.rb
class ToolRegistry
  TOOLS = {
    "notes"        => NotesTool,
    "memory"       => MemoryTool,
    "vault"        => VaultTool,
    "handoff"      => HandoffTool,
    "web_search"   => WebSearchTool,
    "code_execute" => CodeExecuteTool
  }.freeze

  def self.resolve(name)
    TOOLS[name]
  end

  # Build tool instances with dependency injection
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

---

## Long-term memory: the five-layer approach

Drawing from ChatGPT's reverse-engineered architecture and Claude's transparent file-based model, the memory system uses **five layers**, each serving a distinct purpose in retrieval.

**Layer 1 — Session context** (ephemeral): channel type, device info, current agent, active tools. Injected as a system message at session start. Never persisted beyond the session.

**Layer 2 — Explicit memories** (persistent, user-controllable): the `memories` table. Users can say "remember that I prefer TypeScript over JavaScript" and the MemoryTool stores it with an importance score and embedding. These are always injected into every prompt, ChatGPT-style — **no selective retrieval for the first ~50 memories**. The bet, validated by OpenAI's production system, is that models are smart enough to ignore irrelevant context.

**Layer 3 — Conversation summaries** (cross-session): the `conversation_archives` table. After a session goes cold (no activity for 24 hours), a background job summarizes it into key facts and stores the summary with an embedding. These are retrieved via semantic search at session start — only the 5 most relevant archived summaries are injected.

**Layer 4 — Active session messages** (sliding window): the current session's messages, managed by the compaction system. Recent messages stay verbatim; older ones get summarized.

**Layer 5 — User knowledge synthesis** (periodic): a background job runs daily per user, synthesizing all memories, notes, and recent conversations into a dense 2-3 paragraph user profile stored in the user record. This mirrors ChatGPT's "User Knowledge Memories" layer — expensive to generate but cheap to inject.

```ruby
# app/services/memory_retrieval_service.rb
class MemoryRetrievalService
  TOKEN_BUDGET = {
    system_instructions: 0.12,  # 12% of context window
    memories:            0.10,  # 10%
    vault_context:       0.15,  # 15%
    conversation_history: 0.38, # 38%
    response_reserve:    0.25   # 25%
  }.freeze

  def initialize(session:, user:)
    @session = session
    @user = user
    @window = session.context_window_size
  end

  def build_context
    budget = TOKEN_BUDGET.transform_values { |pct| (@window * pct).to_i }

    {
      memories: fetch_memories(budget[:memories]),
      archives: fetch_relevant_archives(budget[:vault_context]),
      user_profile: @user.synthesized_profile.truncate(budget[:memories] * 4),
      messages: fetch_windowed_messages(budget[:conversation_history])
    }
  end

  private

  def fetch_memories(token_budget)
    @user.memories.active.order(importance: :desc, updated_at: :desc).limit(50)
  end

  def fetch_relevant_archives(token_budget)
    return [] if @session.messages.count < 3
    recent_content = @session.messages.last(3).map(&:content).join(" ")
    embedding = RubyLLM.embed(recent_content).vectors
    ConversationArchive.nearest_neighbors(:embedding, embedding, distance: "cosine").limit(5)
  end

  def fetch_windowed_messages(token_budget)
    messages = @session.messages.for_context.to_a
    return messages if estimated_tokens(messages) <= token_budget

    # Keep all messages within budget, starting from most recent
    kept = []
    remaining = token_budget
    messages.reverse_each do |msg|
      est = estimate_message_tokens(msg)
      break if remaining - est < 0
      kept.unshift(msg)
      remaining -= est
    end

    # Prepend summary of excluded messages if session has one
    if @session.summary.present?
      kept.unshift(Message.new(role: "system", content: "[Conversation summary]: #{@session.summary}"))
    end

    kept
  end

  def estimate_message_tokens(msg)
    (msg.content.to_s.length / 4.0).ceil + 4  # ~4 chars per token + message overhead
  end

  def estimated_tokens(messages)
    messages.sum { |m| estimate_message_tokens(m) }
  end
end
```

---

## Compaction: context window and database-level strategies

Two distinct compaction mechanisms operate at different timescales. **Context-window compaction** summarizes old messages to keep conversations within token limits. **Database archival** moves cold conversation data to compressed storage.

```ruby
# app/services/compaction_service.rb
class CompactionService
  SUMMARY_MODEL = "gpt-4o-mini"  # cheap, fast summarizer
  PRESERVE_RECENT = 10           # always keep last N messages verbatim
  PROTECTED_PATTERNS = [
    /```[\s\S]+?```/,            # code blocks
    /error|exception|fail/i,     # error context
    /decision:|decided:|agreed:/i # key decisions
  ].freeze

  def initialize(session)
    @session = session
  end

  # ── Context window compaction ──
  def compact!
    messages = @session.messages.uncompacted.order(:created_at).to_a
    return if messages.size <= PRESERVE_RECENT

    to_compact = messages[0...-PRESERVE_RECENT]
    to_keep    = messages[-PRESERVE_RECENT..]

    # Extract high-value content before summarizing
    preserved_facts = extract_preserved_content(to_compact)

    # Generate summary using a cheap model
    summary_prompt = <<~PROMPT
      Summarize this conversation segment concisely. Preserve:
      - Key decisions and their rationale
      - Specific facts, numbers, file paths, error messages
      - User preferences and instructions
      - Tool call results that informed decisions
      Discard greetings, acknowledgments, and verbose explanations.

      #{preserved_facts}

      Conversation to summarize:
      #{format_messages_for_summary(to_compact)}
    PROMPT

    summary = RubyLLM.chat(model: SUMMARY_MODEL)
                     .with_temperature(0.1)
                     .ask(summary_prompt)
                     .content

    ActiveRecord::Base.transaction do
      to_compact.each { |m| m.update!(compacted: true) }
      @session.update!(summary: summary)

      # Update token estimate
      new_total = estimate_session_tokens(@session)
      @session.update!(total_tokens: new_total)
    end

    Rails.logger.info "[Compaction] Session #{@session.id}: " \
      "#{to_compact.size} messages compacted, " \
      "#{to_keep.size} preserved, " \
      "summary: #{summary.length} chars"
  end

  # ── Database-level archival ──
  def self.archive_cold_sessions!
    Session.where(status: "active")
           .where("updated_at < ?", 24.hours.ago)
           .where("total_tokens > ?", 1000)
           .find_each do |session|
      archive_session(session)
    end
  end

  def self.archive_session(session)
    messages = session.messages.order(:created_at)
    return if messages.empty?

    # Generate archive summary
    key_messages = messages.where("importance >= ?", 7)
                          .or(messages.where(role: "user"))
                          .limit(50)

    summary_content = key_messages.map { |m| "#{m.role}: #{m.content.truncate(200)}" }.join("\n")
    summary = RubyLLM.chat(model: SUMMARY_MODEL)
                     .ask("Summarize this conversation into key facts and decisions:\n#{summary_content}")
                     .content

    key_facts = key_messages.where("importance >= 8")
                            .pluck(:content)
                            .map { |c| c.truncate(200) }

    embedding = RubyLLM.embed(summary).vectors

    ConversationArchive.create!(
      session: session,
      summary: summary,
      key_facts: key_facts,
      message_count: messages.count,
      total_tokens: session.total_tokens,
      embedding: embedding,
      date_range: messages.first.created_at..messages.last.created_at
    )

    # Mark session as archived but keep messages for 30 days
    session.update!(status: "archived")
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

  def format_messages_for_summary(messages)
    messages.map { |m| "[#{m.role}] #{m.content.to_s.truncate(500)}" }.join("\n")
  end

  def estimate_session_tokens(session)
    base = (session.summary.to_s.length / 4.0).ceil
    recent = session.messages.uncompacted.sum { |m| (m.content.to_s.length / 4.0).ceil + 4 }
    base + recent
  end
end
```

Schedule recurring archival with Solid Queue:

```yaml
# config/recurring.yml
production:
  compact_stale_sessions:
    class: ArchiveStaleSessionsJob
    schedule: every 6 hours
  synthesize_user_profiles:
    class: SynthesizeUserProfilesJob
    schedule: every day at 3am
  prune_archived_messages:
    class: PruneArchivedMessagesJob
    schedule: every week on monday at 2am
  refresh_embeddings:
    class: RefreshEmbeddingsJob
    schedule: every 15 minutes
```

---

## Streaming architecture: Falcon fibers meet Action Cable

Falcon's fiber-based concurrency is the critical enabler for this system. Each LLM API call blocks for 5-60 seconds, but with Falcon, that blocking call yields its fiber, allowing thousands of concurrent streaming connections in a single process. **This eliminates the thread pool exhaustion problem that Puma hits with just 25 concurrent LLM calls.**

```ruby
# config/environments/production.rb
config.active_support.isolation_level = :fiber  # Required for Falcon

# Action Cable with Redis adapter for cross-process pub/sub
config.action_cable.adapter = :redis
config.action_cable.url = ENV["REDIS_URL"]

# Solid Queue for standard jobs, Async for LLM-bound work
config.active_job.queue_adapter = :solid_queue
```

```ruby
# app/channels/session_channel.rb
class SessionChannel < ApplicationCable::Channel
  def subscribed
    session = Session.find(params[:session_id])
    reject unless session.user_id == current_user.id
    stream_from "session_#{session.id}"
  end

  def receive(data)
    session = Session.find(params[:session_id])
    ChatStreamJob.perform_later(session.id, current_user.id, data["message"])
  end
end
```

```ruby
# app/jobs/chat_stream_job.rb
class ChatStreamJob < ApplicationJob
  queue_as :llm  # Dedicated queue for LLM operations

  def perform(session_id, user_id, user_message)
    session = Session.find(session_id)
    user = User.find(user_id)
    runtime = AgentRuntime.new(session: session, user: user)

    runtime.run(user_message) do |chunk|
      next unless chunk.content.present?
      ActionCable.server.broadcast("session_#{session.id}", {
        type: "token",
        content: chunk.content,
        message_id: session.messages.last&.id
      })
    end

    ActionCable.server.broadcast("session_#{session.id}", {
      type: "complete",
      message_id: session.messages.last&.id
    })
  rescue => e
    ActionCable.server.broadcast("session_#{session.id}", {
      type: "error",
      message: "Something went wrong. Please try again."
    })
    Rails.logger.error "[ChatStream] Error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
  end
end
```

For Falcon's full async potential with LLM calls, the `async` gem enables concurrent fan-out:

```ruby
# app/services/parallel_agent_executor.rb
require "async"
require "async/semaphore"

class ParallelAgentExecutor
  def initialize(max_concurrent: 5)
    @semaphore = Async::Semaphore.new(max_concurrent)
  end

  # Fan-out to multiple agents, fan-in results
  def execute_parallel(agent_slugs, prompt:, user:, channel:)
    Async do
      agent_slugs.map do |slug|
        @semaphore.async do
          session = SessionResolver.resolve(
            user: user, agent_slug: slug, channel_type: channel.channel_type,
            external_id: channel.external_id
          )
          runtime = AgentRuntime.new(session: session, user: user)
          { agent: slug, result: runtime.run(prompt) }
        end
      end.map(&:wait)
    end.wait
  end
end
```

---

## Embedding generation and background processing

Embeddings are generated asynchronously to avoid blocking the request cycle. The job is idempotent and uses Solid Queue's concurrency controls to prevent duplicate processing.

```ruby
# app/jobs/generate_embedding_job.rb
class GenerateEmbeddingJob < ApplicationJob
  queue_as :embeddings
  limits_concurrency to: 10, key: "embedding_generation"

  def perform(model_name, record_id)
    record = model_name.constantize.find(record_id)
    content = case record
              when Memory then record.content
              when Note then "#{record.title}\n#{record.content}"
              when VaultDocument then "#{record.title}\n#{record.content}"
              when ConversationArchive then record.summary
              end

    embedding = RubyLLM.embed(content.truncate(8000)).vectors
    record.update_column(:embedding, embedding)
  rescue ActiveRecord::RecordNotFound
    # Record was deleted before job ran; safe to ignore
  end
end
```

```ruby
# app/jobs/memory_extraction_job.rb — Auto-extract memories from conversations
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

  def perform(session_id, response_content)
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
      next if mem["importance"] < 6  # Only store important memories

      # Check for duplicates via semantic similarity
      existing = session.user.memories.active
        .nearest_neighbors(:embedding, RubyLLM.embed(mem["content"]).vectors, distance: "cosine")
        .first
      next if existing && existing.neighbor_distance < 0.1  # Too similar

      session.user.memories.create!(
        content: mem["content"],
        category: mem["category"],
        importance: mem["importance"],
        session: session
      )
    end
  end
end
```

---

## Putting it together: the full request flow

A message arriving from any channel follows this path through the system:

```
Telegram webhook / Web UI Action Cable / API POST
  │
  ▼
ChannelController#receive
  │ Resolves: user, channel, agent
  │ Calls: SessionResolver.resolve(...)
  ▼
ChatStreamJob.perform_later(session_id, user_id, message)
  │
  ▼ (Solid Queue dispatches to worker)
AgentRuntime.new(session:, user:)
  │
  ├─ CompactionService.compact! (if context > 75%)
  ├─ MemoryRetrievalService.build_context
  │    ├─ Layer 2: Explicit memories (top 50 by importance)
  │    ├─ Layer 3: Relevant archived conversations (top 5 by similarity)
  │    └─ Layer 5: Synthesized user profile
  ├─ Build RubyLLM::Chat with tools, instructions, context
  │
  ▼ ── ReAct Loop (inside ruby_llm) ──
  │ LLM inference → tool call? → execute tool → feed result → loop
  │    ├─ NotesTool, MemoryTool, VaultTool (local execution)
  │    ├─ HandoffTool → spawns new AgentRuntime for target agent
  │    └─ Built-in tools via Responses API (web search, code interpreter)
  │
  ▼ ── Streaming ──
  │ Each chunk → ActionCable broadcast → WebSocket → client
  │ Each chunk → TelegramAdapter.send (batched) → Telegram API
  │
  ▼ ── Post-processing ──
  ├─ MemoryExtractionJob.perform_later (async)
  ├─ GenerateEmbeddingJob for new notes/memories (async)
  └─ Update session.total_tokens
```

---

## Key architectural decisions and their rationale

**Why a flat message list, not a tree.** Claude Code's architecture proves that a single flat conversation history with one sub-agent branch at a time outperforms complex threading. Trees create ambiguity about which context matters; flat lists are debuggable and predictable.

**Why inject all memories into every prompt.** ChatGPT's production architecture does exactly this — no RAG for the first ~50 memories, just dump them all in. Models are reliably good at ignoring irrelevant context, and the cost of including 50 short memories (~2K tokens) is trivial compared to the risk of failing to retrieve a critical memory.

**Why HNSW over IVFFlat.** The data is constantly growing (new messages, memories, vault documents every session). HNSW handles inserts without index rebuilds and delivers **~1.5ms query latency with 95%+ recall** at default settings. IVFFlat requires periodic retraining and its recall degrades as data distribution shifts.

**Why Falcon over Puma.** A single Falcon process handles thousands of concurrent LLM streaming connections via fibers, each consuming ~4KB of memory. Puma would need 25+ threads to match, each consuming megabytes and a database connection. For a system where the dominant workload is waiting on external API calls, fiber-based concurrency is not optional — it is the correct architectural choice.

**Why both ruby_llm providers.** The standard provider gives multi-model flexibility (Anthropic for reasoning-heavy tasks, Gemini for cost efficiency). The Responses API provider gives server-side state management, built-in tools, and automatic compaction for OpenAI models. Using both via the same `chat.ask` API means agent definitions can switch providers without code changes.

---

## Conclusion: what makes this architecture production-ready

Three properties distinguish this design from a naive implementation. First, **the compaction pipeline operates proactively** — triggering at 75% context utilization rather than reactively at 95%, following the empirical finding that model quality degrades well before the hard limit. The three-stage pipeline (tool-output pruning → LLM summarization → emergency truncation) mirrors Microsoft's Agent Framework approach. Second, **the memory system is layered by volatility and cost** — ephemeral session context costs nothing, explicit memories are cheap to inject, conversation archives use semantic search only when needed, and the synthesized user profile runs once daily. This avoids the common trap of building an expensive RAG pipeline for data that fits in a single system message. Third, **the agent handoff mechanism treats routing as tool execution** rather than a separate orchestration layer — meaning the LLM's native reasoning about when to delegate is the routing logic, with explicit scope boundaries preventing infinite handoff loops. The entire system runs on four infrastructure components (PostgreSQL with pgvector, Redis for pub/sub, Falcon for fiber concurrency, Solid Queue for background jobs) with no external vector database, no graph database, and no message broker beyond what Rails provides.

---

# Addendum: BYOK, MCP, RLS, Cost Tracking, Data-Driven Agents, GoodJob

This addendum supersedes conflicting sections in the base architecture spec.

---

## 1. BYOK — Bring Your Own Key

ruby_llm v1.3+ provides `RubyLLM.context` — an isolated configuration scope that inherits from the global config but overrides specific keys. This is the exact mechanism for per-tenant and per-user API key isolation.

### Schema: API Keys

```ruby
# db/migrate/003_create_api_credentials.rb
class CreateApiCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :api_credentials, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :user,   type: :uuid, foreign_key: true  # nil = tenant-level default
      t.string     :provider,    null: false  # "openai", "anthropic", "openrouter"
      t.text       :api_key_enc, null: false  # encrypted via Rails credentials or attr_encrypted
      t.string     :api_base                  # custom endpoint (e.g. Azure, self-hosted)
      t.boolean    :active,      default: true
      t.jsonb      :metadata,    default: {}  # org_id for openrouter, project_id, etc.
      t.timestamps
      t.index [:tenant_id, :user_id, :provider], unique: true,
              name: "idx_api_creds_unique"
    end
  end
end
```

### Model with encryption

```ruby
# app/models/api_credential.rb
class ApiCredential < ApplicationRecord
  belongs_to :tenant
  belongs_to :user, optional: true

  encrypts :api_key_enc, deterministic: false  # Rails 8 encryption

  validates :provider, presence: true,
    inclusion: { in: %w[openai anthropic openrouter] }
  validates :provider, uniqueness: { scope: [:tenant_id, :user_id] }

  scope :active, -> { where(active: true) }

  # Resolution order: user-specific → tenant default
  def self.resolve(tenant:, user:, provider:)
    find_by(tenant: tenant, user: user, provider: provider, active: true) ||
    find_by(tenant: tenant, user_id: nil, provider: provider, active: true)
  end

  def api_key
    api_key_enc  # decrypted automatically by Rails
  end
end
```

### Context builder — the core BYOK mechanism

```ruby
# app/services/llm_context_builder.rb
class LlmContextBuilder
  PROVIDER_KEY_MAP = {
    "openai"     => :openai_api_key,
    "anthropic"  => :anthropic_api_key,
    "openrouter" => :openrouter_api_key
  }.freeze

  PROVIDER_BASE_MAP = {
    "openai"     => :openai_api_base,
    "anthropic"  => :anthropic_api_base,
    "openrouter" => :openrouter_api_base
  }.freeze

  def self.build(tenant:, user:)
    RubyLLM.context do |config|
      %w[openai anthropic openrouter].each do |provider|
        cred = ApiCredential.resolve(tenant: tenant, user: user, provider: provider)
        next unless cred

        key_attr  = PROVIDER_KEY_MAP[provider]
        base_attr = PROVIDER_BASE_MAP[provider]

        config.send(:"#{key_attr}=", cred.api_key)
        config.send(:"#{base_attr}=", cred.api_base) if cred.api_base.present?
      end
    end
  end
end
```

### Usage in AgentRuntime (replaces `RubyLLM.chat`)

```ruby
# In AgentRuntime#build_chat, replace:
#   RubyLLM.chat(model: ...)
# with:
def build_chat
  ctx = LlmContextBuilder.build(tenant: @tenant, user: @user)

  chat = ctx.chat(model: resolve_model_id)

  chat.with_instructions(load_instructions)
      .with_tools(*resolve_tools)
      .with_temperature(@agent_config.temperature)
      # ...
end
```

`RubyLLM.context` creates an isolated config copy. The global config remains untouched. Each fiber/thread gets its own context — safe under Falcon's concurrency model.

### Key validation endpoint

```ruby
# app/controllers/api/v1/api_credentials_controller.rb
class Api::V1::ApiCredentialsController < ApplicationController
  def create
    cred = current_tenant.api_credentials.build(credential_params)
    cred.user = current_user if params[:scope] == "personal"

    # Validate the key actually works
    ctx = RubyLLM.context do |c|
      c.send(:"#{LlmContextBuilder::PROVIDER_KEY_MAP[cred.provider]}=", cred.api_key)
    end

    begin
      ctx.chat(model: test_model_for(cred.provider)).ask("ping")
      cred.save!
      render json: { status: "valid", id: cred.id }
    rescue RubyLLM::UnauthorizedError
      render json: { error: "Invalid API key" }, status: :unprocessable_entity
    end
  end

  private

  def test_model_for(provider)
    { "openai" => "gpt-4o-mini",
      "anthropic" => "claude-haiku-4-5",
      "openrouter" => "openai/gpt-4o-mini" }[provider]
  end
end
```

---

## 2. MCP Support — Tenant/User Configurable

`ruby_llm-mcp` (v1.0.0) provides first-class MCP client integration with RubyLLM. It supports `stdio`, `streamable` (HTTP), and `sse` transports, plus OAuth 2.1 with per-user Rails integration.

### Schema: MCP Server Configurations

```ruby
# db/migrate/004_create_mcp_server_configs.rb
class CreateMcpServerConfigs < ActiveRecord::Migration[8.0]
  def change
    create_table :mcp_server_configs, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :user,   type: :uuid, foreign_key: true  # nil = tenant-level
      t.string     :name,           null: false  # "github", "slack", "filesystem"
      t.string     :transport_type, null: false, default: "streamable"
      t.string     :url                          # for streamable/sse
      t.jsonb      :stdio_config,   default: {}  # { command:, args:, env: }
      t.jsonb      :oauth_config,   default: {}  # { scope:, client_id:, ... }
      t.text       :oauth_token_enc              # encrypted OAuth token
      t.boolean    :active,         default: true
      t.string     :allowed_tools,  array: true, default: []  # empty = all tools
      t.string     :blocked_tools,  array: true, default: []
      t.jsonb      :metadata,       default: {}
      t.timestamps
      t.index [:tenant_id, :user_id, :name], unique: true
    end
  end
end
```

### MCP Client Manager

```ruby
# app/services/mcp_client_manager.rb
class McpClientManager
  # Cache clients per-process to reuse connections (MCP servers are stateful)
  CLIENTS = Concurrent::Map.new

  def self.clients_for(tenant:, user:)
    configs = McpServerConfig.where(tenant: tenant, active: true)
                             .where("user_id IS NULL OR user_id = ?", user.id)

    configs.map do |config|
      cache_key = "#{config.id}:#{config.updated_at.to_i}"
      CLIENTS.compute_if_absent(cache_key) { build_client(config) }
    end
  end

  def self.tools_for(tenant:, user:)
    clients_for(tenant: tenant, user: user).flat_map do |client|
      tools = client.tools
      config = client.instance_variable_get(:@_config)  # retrieve filter config

      # Apply allow/block lists
      if config.allowed_tools.any?
        tools = tools.select { |t| t.name.in?(config.allowed_tools) }
      end
      tools = tools.reject { |t| t.name.in?(config.blocked_tools) }

      tools
    end
  end

  def self.build_client(config)
    client_opts = {
      name: config.name,
      transport_type: config.transport_type.to_sym
    }

    case config.transport_type
    when "streamable", "sse"
      client_opts[:config] = { url: config.url }
      if config.oauth_token_enc.present?
        client_opts[:config][:headers] = {
          "Authorization" => "Bearer #{config.oauth_token}"
        }
      end
      if config.oauth_config.present?
        client_opts[:config][:oauth] = config.oauth_config.symbolize_keys
      end
    when "stdio"
      client_opts[:config] = config.stdio_config.symbolize_keys
    end

    client = RubyLLM::MCP.client(**client_opts)
    client.instance_variable_set(:@_config, config)  # stash for filtering
    client
  end

  # Cleanup on config change
  def self.invalidate(config_id)
    CLIENTS.each_pair do |key, _|
      CLIENTS.delete(key) if key.start_with?("#{config_id}:")
    end
  end
end
```

### Integration with AgentRuntime

```ruby
# In AgentRuntime#build_chat, after adding local tools:
def resolve_tools
  local_tools = ToolRegistry.build(@agent_config.tool_names, user: @user, session: @session)
  mcp_tools   = McpClientManager.tools_for(tenant: @tenant, user: @user)

  local_tools + mcp_tools
end
```

MCP tools returned by `ruby_llm-mcp` are already `RubyLLM::Tool`-compatible — they plug directly into `chat.with_tools(*)` with zero adapter code.

### Per-user OAuth flow (Rails)

After running `rails generate ruby_llm:mcp:oauth:install User`, users can authenticate to MCP servers via OAuth 2.1:

```ruby
# app/controllers/mcp/oauth_controller.rb
class Mcp::OauthController < ApplicationController
  def initiate
    config = current_tenant.mcp_server_configs.find(params[:id])
    client = McpClientManager.build_client(config)

    redirect_url = client.oauth(type: :web).authorization_url(
      redirect_uri: mcp_oauth_callback_url(config_id: config.id)
    )
    redirect_to redirect_url, allow_other_host: true
  end

  def callback
    config = current_tenant.mcp_server_configs.find(params[:config_id])
    client = McpClientManager.build_client(config)

    token = client.oauth(type: :web).exchange_code(
      code: params[:code],
      redirect_uri: mcp_oauth_callback_url(config_id: config.id)
    )

    config.update!(oauth_token_enc: token)
    McpClientManager.invalidate(config.id)

    redirect_to settings_integrations_path, notice: "Connected!"
  end
end
```

---

## 3. Tenant & User Isolation via PostgreSQL RLS

RLS enforces data boundaries at the database level. Even if application code has a bug that omits a `WHERE tenant_id = ?`, the database silently filters rows. This is defense-in-depth.

### Architecture

The pattern uses PostgreSQL session variables (`SET LOCAL app.current_tenant_id`), which are transaction-scoped. A Rails middleware sets the variable on every request. Background jobs set it before execution.

### Database setup

```ruby
# db/migrate/005_setup_rls.rb
class SetupRls < ActiveRecord::Migration[8.0]
  def up
    # Create a non-superuser role for the app
    # (superusers bypass RLS — the app MUST connect as this role)
    execute <<~SQL
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
          CREATE ROLE app_user LOGIN PASSWORD '#{Rails.application.credentials.db_app_password}';
        END IF;
      END $$;
    SQL

    # Add tenant_id to all tenant-scoped tables
    TENANT_SCOPED_TABLES.each do |table|
      next if column_exists?(table, :tenant_id)
      add_reference table, :tenant, type: :uuid, null: false, foreign_key: true
      add_index table, :tenant_id
    end

    # Enable RLS and create policies
    TENANT_SCOPED_TABLES.each do |table|
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;"

      execute <<~SQL
        CREATE POLICY tenant_isolation ON #{table}
          FOR ALL
          TO app_user
          USING (tenant_id::text = current_setting('app.current_tenant_id', true))
          WITH CHECK (tenant_id::text = current_setting('app.current_tenant_id', true));
      SQL
    end

    # Grant permissions to app_user
    TENANT_SCOPED_TABLES.each do |table|
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO app_user;"
    end
    execute "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;"
  end

  TENANT_SCOPED_TABLES = %w[
    agents sessions channels messages tool_calls
    memories notes vault_documents vault_links
    conversation_archives api_credentials mcp_server_configs
    usage_records
  ].freeze
end
```

### Middleware

```ruby
# app/middleware/tenant_rls_middleware.rb
class TenantRlsMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    tenant_id = resolve_tenant(request)

    if tenant_id
      set_rls_context(tenant_id) { @app.call(env) }
    else
      @app.call(env)
    end
  end

  private

  def resolve_tenant(request)
    # Strategy 1: subdomain
    # Strategy 2: API key header
    # Strategy 3: JWT claim
    # Implement based on your auth strategy
    request.env["current_tenant_id"]
  end

  def set_rls_context(tenant_id)
    ActiveRecord::Base.connection.execute(
      "SET LOCAL app.current_tenant_id = #{ActiveRecord::Base.connection.quote(tenant_id)}"
    )
    yield
  ensure
    ActiveRecord::Base.connection.execute(
      "RESET app.current_tenant_id"
    )
  end
end

# config/application.rb
config.middleware.insert_after ActionDispatch::Session::CookieStore, TenantRlsMiddleware
```

### GoodJob integration — setting RLS in background jobs

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  around_perform do |job, block|
    tenant_id = job.arguments.first.try(:[], :tenant_id) ||
                job.tenant_id_from_record

    if tenant_id
      ActiveRecord::Base.connection.execute(
        "SET LOCAL app.current_tenant_id = #{ActiveRecord::Base.connection.quote(tenant_id)}"
      )
    end
    block.call
  ensure
    ActiveRecord::Base.connection.execute("RESET app.current_tenant_id") if tenant_id
  end
end
```

### Database connection config

```yaml
# config/database.yml
production:
  primary:
    adapter: postgresql
    username: app_user          # NOT the superuser
    password: <%= Rails.application.credentials.db_app_password %>
    # ...
  primary_admin:
    adapter: postgresql
    username: postgres          # superuser for migrations only
    password: <%= Rails.application.credentials.db_admin_password %>
    migrations_paths: db/migrate
```

**Critical**: The application must connect as `app_user` (non-superuser), because PostgreSQL superusers bypass RLS entirely.

---

## 4. Token & Cost Tracking

### Schema

```ruby
# db/migrate/006_create_usage_records.rb
class CreateUsageRecords < ActiveRecord::Migration[8.0]
  def change
    create_table :usage_records, id: :uuid do |t|
      t.references :tenant,  type: :uuid, null: false, foreign_key: true
      t.references :user,    type: :uuid, foreign_key: true
      t.references :session, type: :uuid, foreign_key: true
      t.references :message, type: :uuid, foreign_key: true
      t.string     :agent_slug
      t.string     :model_id,       null: false
      t.string     :provider,       null: false
      t.string     :request_type,   default: "chat"  # chat, embedding, image
      t.integer    :input_tokens,   default: 0
      t.integer    :output_tokens,  default: 0
      t.integer    :cached_tokens,  default: 0
      t.integer    :thinking_tokens, default: 0
      t.decimal    :input_cost,     precision: 12, scale: 8, default: 0
      t.decimal    :output_cost,    precision: 12, scale: 8, default: 0
      t.decimal    :total_cost,     precision: 12, scale: 8, default: 0
      t.string     :currency,       default: "USD"
      t.integer    :duration_ms
      t.jsonb      :metadata,       default: {}
      t.timestamps
      t.index [:tenant_id, :created_at]
      t.index [:tenant_id, :user_id, :created_at]
      t.index [:model_id, :created_at]
    end

    # Daily aggregates for fast dashboard queries
    create_table :usage_daily_summaries, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :user,   type: :uuid, foreign_key: true
      t.date       :date,        null: false
      t.string     :model_id
      t.string     :provider
      t.integer    :request_count, default: 0
      t.integer    :total_input_tokens,  default: 0
      t.integer    :total_output_tokens, default: 0
      t.decimal    :total_cost, precision: 12, scale: 6, default: 0
      t.timestamps
      t.index [:tenant_id, :date], unique: false
      t.index [:tenant_id, :user_id, :date, :model_id],
              unique: true, name: "idx_usage_daily_unique"
    end
  end
end
```

### Cost calculator

```ruby
# app/services/cost_calculator.rb
class CostCalculator
  # Prices per 1M tokens (USD) — refreshed from RubyLLM.models registry
  def self.calculate(model_id:, input_tokens:, output_tokens:, cached_tokens: 0)
    model = RubyLLM.models.find(model_id)
    return zero_cost unless model

    input_price  = model.metadata.dig("pricing", "input")  || 0
    output_price = model.metadata.dig("pricing", "output") || 0
    cached_price = model.metadata.dig("pricing", "cached_input") || (input_price * 0.5)

    billable_input = input_tokens - cached_tokens
    input_cost  = (billable_input * input_price / 1_000_000.0)
    cached_cost = (cached_tokens * cached_price / 1_000_000.0)
    output_cost = (output_tokens * output_price / 1_000_000.0)

    {
      input_cost: (input_cost + cached_cost).round(8),
      output_cost: output_cost.round(8),
      total_cost: (input_cost + cached_cost + output_cost).round(8)
    }
  end

  def self.zero_cost
    { input_cost: 0, output_cost: 0, total_cost: 0 }
  end
end
```

### Recording usage — hooked into AgentRuntime

```ruby
# app/services/usage_recorder.rb
class UsageRecorder
  def self.record(message:, session:, tenant:, user:)
    return unless message.input_tokens.to_i > 0 || message.output_tokens.to_i > 0

    model_id = session.model_id || session.agent.model_id
    provider = session.provider || session.agent.provider || "auto"

    costs = CostCalculator.calculate(
      model_id: model_id,
      input_tokens: message.input_tokens.to_i,
      output_tokens: message.output_tokens.to_i,
      cached_tokens: message.cached_tokens.to_i
    )

    UsageRecord.create!(
      tenant: tenant,
      user: user,
      session: session,
      message: message,
      agent_slug: message.agent_slug,
      model_id: model_id,
      provider: provider,
      input_tokens: message.input_tokens.to_i,
      output_tokens: message.output_tokens.to_i,
      cached_tokens: message.cached_tokens.to_i,
      thinking_tokens: message.thinking_tokens.to_i,
      duration_ms: message.metadata&.dig("duration_ms"),
      **costs
    )
  end
end
```

### Daily aggregation job

```ruby
# app/jobs/aggregate_usage_job.rb
class AggregateUsageJob < ApplicationJob
  queue_as :maintenance

  def perform(date = Date.yesterday)
    UsageRecord.where(created_at: date.all_day)
               .group(:tenant_id, :user_id, :model_id, :provider)
               .select(
                 :tenant_id, :user_id, :model_id, :provider,
                 "COUNT(*) as request_count",
                 "SUM(input_tokens) as total_input_tokens",
                 "SUM(output_tokens) as total_output_tokens",
                 "SUM(total_cost) as total_cost"
               ).each do |row|
      UsageDailySummary.upsert(
        {
          tenant_id: row.tenant_id, user_id: row.user_id,
          date: date, model_id: row.model_id, provider: row.provider,
          request_count: row.request_count,
          total_input_tokens: row.total_input_tokens,
          total_output_tokens: row.total_output_tokens,
          total_cost: row.total_cost
        },
        unique_by: :idx_usage_daily_unique
      )
    end
  end
end
```

### Budget enforcement (optional)

```ruby
# app/services/budget_enforcer.rb
class BudgetEnforcer
  class BudgetExceededError < StandardError; end

  def self.check!(tenant:, user: nil)
    return unless tenant.monthly_budget_usd

    spent = UsageRecord.where(tenant: tenant)
                       .where(created_at: Time.current.beginning_of_month..)
                       .sum(:total_cost)

    if spent >= tenant.monthly_budget_usd
      raise BudgetExceededError,
        "Monthly budget of $#{tenant.monthly_budget_usd} exceeded (spent: $#{spent.round(2)})"
    end
  end
end
```

---

## 5. Agents as Data, Not Classes

Agents are fully user-defined via database rows and JSONB. No Ruby classes per agent. The `Agent` model stores everything: identity, instructions, model, tools, thinking config, handoff targets.

### Revised Agent model

```ruby
# app/models/agent.rb
class Agent < ApplicationRecord
  belongs_to :tenant
  has_many :sessions, dependent: :destroy

  validates :slug, presence: true, uniqueness: { scope: :tenant_id }
  validates :model_id, presence: true

  # All agent configuration is in the DB row:
  #
  # slug:              "research-agent"
  # name:              "Research Assistant"
  # model_id:          "claude-sonnet-4-6"
  # provider:          "anthropic"         (or nil for auto-detect)
  # instructions:      "You are a research..." (full system prompt text)
  # instructions_path: "prompts/research.md.erb" (alternative: ERB template)
  # tool_names:        ["notes", "memory", "vault", "web_search"]
  # handoff_targets:   ["code-agent", "writing-agent"]
  # temperature:       0.7
  # params:            { max_tokens: 8192 }
  #
  # --- NEW: identity/soul/behavior config ---
  # identity:          {
  #   persona: "A meticulous researcher who always cites sources...",
  #   tone: "professional but approachable",
  #   constraints: ["Never make claims without evidence",
  #                 "Always ask clarifying questions when ambiguous"],
  #   examples: [
  #     { user: "Find info on X", assistant: "I'll research X..." }
  #   ]
  # }
  #
  # thinking:          {
  #   enabled: true,
  #   budget_tokens: 10000
  # }

  def resolved_instructions
    base = if instructions_path.present?
      template = File.read(Rails.root.join("app", instructions_path))
      ERB.new(template).result_with_hash(agent: self, identity: identity)
    else
      instructions.to_s
    end

    # Compose final system prompt from identity fields
    parts = [base]

    if identity.present?
      parts << "## Identity\n#{identity['persona']}" if identity["persona"]
      parts << "## Tone\n#{identity['tone']}" if identity["tone"]
      if identity["constraints"].present?
        parts << "## Constraints\n" + identity["constraints"].map { |c| "- #{c}" }.join("\n")
      end
    end

    parts.compact.join("\n\n")
  end

  def thinking_config
    return {} unless thinking.present? && thinking["enabled"]
    {
      thinking: {
        type: "enabled",
        budget_tokens: thinking["budget_tokens"] || 10_000
      }
    }
  end
end
```

### Updated schema (additions to base spec)

```ruby
# Add to agents table:
t.references :tenant,     type: :uuid, null: false, foreign_key: true
t.jsonb      :identity,   default: {}   # persona, tone, constraints, examples
t.jsonb      :thinking,   default: {}   # { enabled: true, budget_tokens: 10000 }

# Uniqueness is now per-tenant
t.index [:tenant_id, :slug], unique: true
# Remove the old global unique index on :slug
```

### AgentRuntime — fully data-driven

```ruby
# app/services/agent_runtime.rb (revised build_chat)
def build_chat
  ctx = LlmContextBuilder.build(tenant: @tenant, user: @user)

  model_id = @session.model_id || @agent.model_id
  provider = @agent.provider&.to_sym

  chat = provider ?
    ctx.chat(model: model_id, provider: provider) :
    ctx.chat(model: model_id)

  chat.with_instructions(@agent.resolved_instructions)
      .with_tools(*resolve_tools)
      .with_temperature(@agent.temperature || 0.7)
      .with_params(**@agent.params.symbolize_keys, **@agent.thinking_config)

  # Wire up callbacks...
  chat
end
```

### Agent CRUD API — users create agents at runtime

```ruby
# app/controllers/api/v1/agents_controller.rb
class Api::V1::AgentsController < ApplicationController
  def create
    agent = current_tenant.agents.build(agent_params)
    if agent.save
      render json: AgentSerializer.new(agent), status: :created
    else
      render json: { errors: agent.errors }, status: :unprocessable_entity
    end
  end

  def update
    agent = current_tenant.agents.find_by!(slug: params[:slug])
    agent.update!(agent_params)
    render json: AgentSerializer.new(agent)
  end

  private

  def agent_params
    params.require(:agent).permit(
      :slug, :name, :model_id, :provider, :instructions,
      :instructions_path, :temperature, :active,
      tool_names: [], handoff_targets: [],
      params: {}, identity: {}, thinking: {},
      metadata: {}
    )
  end
end
```

### Example: user-created agent via API

```json
POST /api/v1/agents
{
  "agent": {
    "slug": "my-code-reviewer",
    "name": "Code Review Bot",
    "model_id": "claude-sonnet-4-6",
    "provider": "anthropic",
    "instructions": "Review code for bugs, security issues, and style violations.",
    "tool_names": ["notes", "vault"],
    "handoff_targets": ["orchestrator"],
    "temperature": 0.3,
    "identity": {
      "persona": "A senior staff engineer with 20 years of experience. Opinionated but fair. Loves clean abstractions and hates premature optimization.",
      "tone": "direct, uses dry humor",
      "constraints": [
        "Always explain WHY something is a problem, not just WHAT",
        "Suggest concrete fixes, never vague advice",
        "If the code is good, say so — don't invent issues"
      ]
    },
    "thinking": {
      "enabled": true,
      "budget_tokens": 8000
    },
    "params": {
      "max_tokens": 4096
    }
  }
}
```

---

## 6. GoodJob Replaces Solid Queue

All references to Solid Queue are replaced with GoodJob. The configuration is straightforward since GoodJob uses the existing Postgres database.

### Setup

```ruby
# Gemfile
gem "good_job", "~> 4.0"

# config/application.rb
config.active_job.queue_adapter = :good_job
```

### Configuration

```ruby
# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.execution_mode = :async_server  # in-process with Falcon
  config.good_job.max_threads = 10
  config.good_job.poll_interval = 5
  config.good_job.shutdown_timeout = 30

  config.good_job.queues = "llm:3;embeddings:2;maintenance:1;default:4"

  config.good_job.enable_cron = true
  config.good_job.cron = {
    archive_stale_sessions: {
      cron: "0 */6 * * *",  # every 6 hours
      class: "ArchiveStaleSessionsJob",
      description: "Archive cold sessions (>24h inactive)"
    },
    synthesize_user_profiles: {
      cron: "0 3 * * *",    # daily at 3am
      class: "SynthesizeUserProfilesJob",
      description: "Regenerate user knowledge synthesis"
    },
    prune_archived_messages: {
      cron: "0 2 * * 1",    # weekly Monday 2am
      class: "PruneArchivedMessagesJob",
      description: "Delete messages from archived sessions >30d old"
    },
    aggregate_daily_usage: {
      cron: "15 0 * * *",   # daily at 00:15
      class: "AggregateUsageJob",
      description: "Roll up usage records into daily summaries"
    },
    refresh_embeddings: {
      cron: "*/15 * * * *", # every 15 minutes
      class: "RefreshEmbeddingsJob",
      description: "Generate embeddings for records missing them"
    }
  }

  # Concurrency controls (replaces Solid Queue's limits_concurrency)
  config.good_job.enable_listen_notify = true  # low-latency via LISTEN/NOTIFY
end
```

### Concurrency control via GoodJob

```ruby
# app/jobs/generate_embedding_job.rb
class GenerateEmbeddingJob < ApplicationJob
  queue_as :embeddings

  # GoodJob concurrency control — replaces Solid Queue's limits_concurrency
  include GoodJob::ActiveJobExtensions::Concurrency

  good_job_control_concurrency_with(
    total_limit: 10,
    key: -> { "embedding_generation" }
  )

  def perform(model_name, record_id, tenant_id:)
    # RLS context is set by ApplicationJob's around_perform
    record = model_name.constantize.find(record_id)
    content = extract_content(record)
    embedding = RubyLLM.embed(content.truncate(8000)).vectors
    record.update_column(:embedding, embedding)
  rescue ActiveRecord::RecordNotFound
    # safe to ignore
  end
end
```

### GoodJob dashboard

```ruby
# config/routes.rb
Rails.application.routes.draw do
  authenticate :admin_user do
    mount GoodJob::Engine => "/good_job"
  end
end
```

GoodJob's built-in web dashboard provides job monitoring, retry management, and cron schedule visibility — equivalent to what Solid Queue's Mission Control provides.

---

## Revised Gemfile (complete)

```ruby
# Gemfile (relevant gems)
gem "rails", "~> 8.0"
gem "pg", "~> 1.5"
gem "redis", "~> 5.0"
gem "falcon", "~> 0.48"

# LLM
gem "ruby_llm", "~> 1.14"
gem "ruby_llm-mcp", "~> 1.0"
gem "ruby_llm-responses_api", "~> 0.5"

# Background jobs
gem "good_job", "~> 4.0"

# Vector search
gem "neighbor", "~> 0.5"  # pgvector ActiveRecord integration

# Encryption
# (Rails 8 built-in ActiveRecord encryption — no extra gem needed)
```

---

## Revised Request Flow (with all corrections applied)

```
Request arrives (Web / Telegram / API)
  │
  ▼
TenantRlsMiddleware
  │ SET LOCAL app.current_tenant_id = '...'
  │ (all subsequent queries are RLS-filtered)
  ▼
SessionResolver.resolve(tenant:, user:, agent_slug:, channel:)
  │ Agent is a DB row, not a class
  ▼
BudgetEnforcer.check!(tenant:, user:)
  │
  ▼
ChatStreamJob.perform_later(session_id, user_id, message, tenant_id:)
  │ (GoodJob picks up from Postgres, sets RLS in around_perform)
  ▼
AgentRuntime.new(session:, user:, tenant:)
  │
  ├─ LlmContextBuilder.build(tenant:, user:)
  │    └─ RubyLLM.context { |c| c.openai_api_key = user's BYOK key }
  │
  ├─ resolve_tools
  │    ├─ ToolRegistry.build(agent.tool_names, ...)  # local tools
  │    └─ McpClientManager.tools_for(tenant:, user:)  # MCP tools
  │
  ├─ Agent#resolved_instructions  # composed from identity/soul/constraints
  │
  ├─ ctx.chat(model: agent.model_id)
  │    .with_tools(...)
  │    .with_instructions(...)
  │    .with_params(**agent.thinking_config)
  │
  ▼ ── ReAct Loop ──
  │ LLM → tool call → execute → feed result → loop
  │
  ▼ ── Post-processing ──
  ├─ UsageRecorder.record(message:, session:, tenant:, user:)
  ├─ MemoryExtractionJob.perform_later(...)
  └─ Stream chunks via ActionCable / channel adapter
```
