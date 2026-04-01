---
type: rfc
title: Agent Session Management
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/01-platform-and-infrastructure
  - prd/03-agentic-system
depends_on:
  - rfc/2026-03-29-simple-chat-conversation
  - rfc/2026-03-31-agent-configuration
phase: 2
---

# RFC: Agent Session Management

## Context

[RFC 002](../rfc-done/2026-03-29-simple-chat-conversation.md) implemented a minimal session model with `SimpleChatService` — no compaction, no context window management, no session archival. Long conversations will eventually hit the LLM's context window limit and fail.

The PRD defines the full session lifecycle ([03 §3](../prd/03-agentic-system.md#3-agent-runtime-react-loop), [03 §5](../prd/03-agentic-system.md#5-session-management), [03 §8](../prd/03-agentic-system.md#8-compaction)): context building, compaction at 75% capacity, and archival of stale sessions. This RFC implements that lifecycle.

**This is the highest-risk RFC in this batch.** It interacts with ruby_llm's `acts_as_chat` in non-trivial ways and introduces asynchronous compaction. The design accounts for 6 critical issues identified during planning.

### What This RFC Covers

- Database migrations: `compacted` boolean + `media_description` on messages, session management columns
- `AgentRuntime` service replacing `SimpleChatService` (compaction check + context build + ask)
- `CompactionService` for summarizing old messages
- `MessageSummarizer` for condensing long messages during compaction (short → verbatim, long → summarized)
- `ContextBuilder` for assembling what the LLM actually sees
- Media message handling: text description instead of raw binary during context replay
- `CompactionJob` — async compaction via GoodJob with concurrency controls
- `ArchiveStaleSessionsJob` — GoodJob cron for session archival
- `ChatStreamJob` update to use `AgentRuntime`

### What This RFC Does NOT Cover

- Tool system / ReAct loop (future RFC — `AgentRuntime` is designed to accept tools later)
- Memory injection (MemoryRetrievalService, memory_entries) (see [PRD 03 §7](../prd/03-agentic-system.md#7-memory-architecture))
- Budget enforcement (BudgetEnforcer, credit checks) (see [PRD 04 §3](../prd/04-billing-and-operations.md#3-credit-model))
- Handoffs (HandoffTool, multi-agent routing) (see [PRD 03 §4](../prd/03-agentic-system.md#4-multi-agent-routing--handoffs))
- Memory extraction (MemoryExtractionJob) — hooks exist but are no-ops until memory ships
- OpenAI Responses API server-side compaction — future optimization
- Voice message processing — see [RFC Voice Message Processing](2026-03-31-voice-message-processing.md) (builds on D7 MessageSummarizer and D8 media_description)

---

## 1. Critical Design Decisions

These decisions resolve issues identified during planning. Each addresses a specific failure mode.

### D1: `acts_as_chat` and the `compacted` flag

**Problem**: ruby_llm's `acts_as_chat` loads ALL messages in the association into the LLM context. It has no concept of a `compacted` boolean. Marking messages as `compacted: true` without filtering the association means compacted messages are still sent to the LLM — defeating the purpose of compaction.

**Solution**: Override the messages association used by `acts_as_chat` with a scoped association that excludes compacted messages:

```ruby
acts_as_chat messages: :context_messages, model_class: "RubyLLM::ModelRecord"

has_many :context_messages,
         -> { where(compacted: [false, nil]).order(:created_at) },
         class_name: "Message",
         foreign_key: :session_id,
         inverse_of: :session

has_many :messages, dependent: :destroy, inverse_of: :session
```

**Spike required**: Verify that ruby_llm respects a custom-named scoped association. If it internally hardcodes `session.messages`, this approach won't work and we need to manage context manually in `ContextBuilder` (dropping `acts_as_chat` for context assembly while keeping it for message persistence).

### D2: Active context tokens vs. lifetime total tokens

**Problem**: `session.total_tokens` is a running lifetime sum. A session with 500k lifetime tokens but only 10 recent messages would falsely report 390% usage and trigger compaction on every message.

**Solution**: Compute active context tokens on-the-fly from non-compacted messages:

```ruby
# Context size ≈ last message's input_tokens (includes all prior context)
# + its output_tokens. Summing input_tokens across all messages would
# double-count because each input_tokens value includes the full prior context.
#
# @return [Integer]
def active_context_tokens
  last_msg = messages.where(compacted: [false, nil]).order(:created_at).last
  return 0 unless last_msg

  last_msg.input_tokens.to_i + last_msg.output_tokens.to_i
end
```

Use `char / 4` heuristic for fast in-request estimates (fiber-safe, no CPU blocking). Accurate token counts come from ruby_llm after the LLM responds.

### D3: Async compaction (not synchronous)

**Problem**: Synchronous compaction during a chat request blocks the user for 5-30+ seconds (LLM summarization call). Under Falcon's fiber model, this also holds a fiber and potentially a DB connection.

**Solution**: Compaction runs asynchronously in a GoodJob worker. When `AgentRuntime` detects context usage >= 75%, it enqueues `CompactionJob` and continues the current chat using the remaining 25% buffer. The next turn benefits from the compaction.

### D4: GoodJob concurrency controls instead of advisory locks

**Problem**: PostgreSQL advisory locks are session-level (connection-level). Under Falcon's fiber concurrency with connection pooling, fibers can inadvertently release another fiber's advisory lock when the connection returns to the pool.

**Solution**: Use GoodJob's built-in concurrency controls:

```ruby
class CompactionJob < ApplicationJob
  good_job_control_concurrency_with(
    perform_limit: 1,
    key: -> { "compaction_#{arguments.first}" }  # session_id
  )
end
```

This ensures at most one compaction runs per session, without holding DB connections.

### D5: Summary preservation across compactions

**Problem**: `session.update!(summary: new_summary)` overwrites the existing summary. Subsequent compactions lose prior context.

**Solution**: Append new summaries and feed the existing summary into the compaction prompt:

```ruby
combined = [@session.summary, new_summary].compact.join("\n\n---\n\n")
@session.update!(summary: combined)
```

The compaction prompt includes the existing summary as prior context, producing an iteratively refined summary.

### D6: Per-user compaction model resolution

**Problem**: `SUMMARY_MODEL = "gpt-4o-mini"` assumes OpenAI access. BYOK users with only Anthropic keys will fail.

**Solution**: Resolve the compaction model per-agent with fallback chain:

```ruby
def compaction_model
  @agent.params&.dig("compaction_model") || @agent.model_id || "gpt-4o-mini"
end
```

### D7: Long message summarization during compaction

**Problem**: When compaction formats messages for the summarization prompt, it truncates each message to 500 characters (`m.content.to_s.truncate(500)`). A user who pastes a 50k-character document gets a compaction summary that only saw the first 500 characters — losing the substance of the message entirely. Compaction must produce useful summaries regardless of individual message length.

**Solution**: A `MessageSummarizer` service that either returns the text verbatim (if short) or produces a condensed version preserving key facts. During compaction, each message is passed through the summarizer before being fed to the compaction prompt. Each message gets a 300-500 character budget in the compaction input.

```ruby
# app/services/message_summarizer.rb
class MessageSummarizer
  CHAR_THRESHOLD = 500   # Messages shorter than this are returned as-is
  TARGET_CHARS   = 400   # Target length for summarized messages

  # Returns the text as-is if it's short enough, or a condensed
  # version that preserves key facts, decisions, and specifics.
  #
  # @param text [String] the original message content
  # @param model [String] LLM model to use for summarization
  # @return [String] original or summarized text
  def self.call(text, model: "gpt-4o-mini")
    return text if text.blank? || text.length <= CHAR_THRESHOLD

    response = RubyLLM.chat(model:)
                      .with_temperature(0.1)
                      .ask(<<~PROMPT)
      Condense this message to ~#{TARGET_CHARS} characters. Preserve ALL:
      - Specific facts, names, numbers, dates, URLs, file paths
      - Key decisions and their rationale
      - Code snippets (abbreviated if long)
      - Error messages
      - Questions asked or instructions given

      Drop: pleasantries, filler, verbose explanations, repeated context.
      Return ONLY the condensed text, no preamble.

      Message:
      #{text}
    PROMPT
    response.content.presence || text.truncate(CHAR_THRESHOLD)
  end
end
```

This is the same pattern used in the compaction pipeline of other projects — a simple gate: short message → pass through, long message → summarize. The compaction service calls it per-message when building the compaction prompt.

### D8: Media message handling during context replay

**Problem**: When the conversation includes images or other media (via multimodal models), replaying the raw binary/base64 data into the context window on subsequent turns is wasteful and often impossible after compaction. An image that consumed 1,000+ tokens in the original turn should not be re-sent on every subsequent turn.

**Solution**: When a message contains media (images, files), the system stores a text description of what was observed alongside the original. During context replay (compaction or context building), only the text description is used — never the raw media.

Implementation:
- Messages with media attachments store the original in `content_raw` (already exists in schema).
- After the assistant processes a media message, a post-processing step extracts a text description: `"[Image: user uploaded a photo showing a restaurant menu with Italian dishes, prices ranging from €12-28]"`.
- During compaction and context replay, `content_for_context` returns this description instead of the raw media payload.
- The `Message` model gets a `media_description` text column (added in migration) and a `content_for_context` method.

```ruby
# On Message model:

# Returns the content appropriate for context replay.
# For media messages, returns the text description instead of raw media.
#
# @return [String]
def content_for_context
  return media_description if media_description.present?

  content.to_s
end
```

The media description is generated by the LLM on the original turn (the model already "sees" the image), extracted via a lightweight post-processing step, and stored for all future context use. This means the image is processed exactly once.

---

## 2. Database Schema

### 2.1 Migration: Add Compaction Columns to Messages

```ruby
# db/migrate/TIMESTAMP_add_compaction_columns_to_messages.rb
class AddCompactionColumnsToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :compacted, :boolean, default: false, null: false
    add_column :messages, :importance, :integer
    add_column :messages, :media_description, :text  # Text description of media content (images, files) for context replay

    # Partial index: only index non-compacted messages (small, fast, cheap).
    # Full [session_id, compacted] index would wastefully include millions
    # of compacted rows that are rarely queried.
    add_index :messages, :session_id,
              where: "compacted = false",
              name: "idx_messages_session_active"
  end
end
```

### 2.2 Migration: Add Session Management Columns

```ruby
# db/migrate/TIMESTAMP_add_session_management_columns.rb
class AddSessionManagementColumns < ActiveRecord::Migration[8.1]
  def change
    safety_assured do
      change_table :sessions, bulk: true do |t|
        t.text     :summary                     # Compacted conversation summary
        t.string   :title                       # Display title (auto-generated or user-set)
        t.jsonb    :context_data, default: {}   # Sliding window metadata
        t.datetime :started_at
        t.datetime :ended_at
      end
    end

    # Backfill started_at from created_at for existing sessions
    reversible do |dir|
      dir.up { execute "UPDATE sessions SET started_at = created_at WHERE started_at IS NULL" }
    end
  end
end
```

All columns are nullable additions — safe with `strong_migrations`.

---

## 3. Model Changes

### 3.1 Session

```ruby
# app/models/session.rb
class Session < ApplicationRecord
  include WorkspaceScoped

  # context_messages excludes compacted messages — this is what the LLM sees.
  acts_as_chat messages: :context_messages, model_class: "RubyLLM::ModelRecord"

  belongs_to :agent

  has_many :context_messages,
           -> { where(compacted: [false, nil]).order(:created_at) },
           class_name: "Message",
           foreign_key: :session_id,
           inverse_of: :session

  has_many :messages, dependent: :destroy, inverse_of: :session

  validates :gateway, presence: true
  validates :status, presence: true, inclusion: { in: %w[active archived] }
  validate :agent_belongs_to_workspace

  scope :active, -> { where(status: "active") }
  scope :stale, ->(threshold = 7.days.ago) { active.where("last_activity_at < ?", threshold) }

  # Finds or creates the active session for the current workspace.
  #
  # @param agent [Agent]
  # @param gateway [String]
  # @return [Session]
  def self.resolve(agent:, gateway: "web")
    workspace = Current.workspace
    raise ArgumentError, "Current.workspace must be set" unless workspace

    session = create_or_find_by!(
      agent:,
      workspace:,
      gateway:,
      status: "active"
    ) do |session|
      session.last_activity_at = Time.current
      session.started_at = Time.current
      session.model = model_record_for(agent.model_id)
    end

    return session if session.model.present?

    session.update!(model: model_record_for(agent.model_id))
    session
  end

  # Context size ≈ last message's input_tokens (includes all prior context)
  # + its output_tokens. Summing input_tokens across all messages would
  # double-count because each input_tokens value includes the full prior context.
  #
  # @return [Integer]
  def active_context_tokens
    last_msg = messages.where(compacted: [false, nil]).order(:created_at).last
    return 0 unless last_msg

    last_msg.input_tokens.to_i + last_msg.output_tokens.to_i
  end

  # Fast heuristic: estimate tokens from character count of active messages.
  # Fiber-safe (no external HTTP calls). Used for in-request threshold checks.
  #
  # @return [Integer]
  def estimated_context_tokens
    total_chars = messages.where(compacted: [false, nil])
                         .sum("coalesce(length(content), 0)")
    (total_chars / 4.0).ceil
  end

  # Context window size for the session's model.
  #
  # @return [Integer]
  def context_window_size
    model_record = RubyLLM::ModelRecord.find_by(model_id: agent.model_id)
    model_record&.metadata&.dig("context_window") || 128_000
  end

  # Ratio of active tokens to context window. Triggers compaction at 0.75.
  #
  # @return [Float]
  def context_window_usage
    window = context_window_size
    return 0.0 if window.zero?

    estimated_context_tokens.to_f / window
  end

  # Archives this session.
  #
  # @return [void]
  def archive!
    update!(status: "archived", ended_at: Time.current)
  end

  private

  def self.model_record_for(model_id)
    RubyLLM::ModelRecord.find_or_create_by!(
      model_id:,
      provider: AgentRuntime::DEFAULT_PROVIDER.to_s
    ) do |model|
      model.name = model_id
      model.capabilities = []
      model.modalities = {}
      model.pricing = {}
      model.metadata = {}
    end
  end
  private_class_method :model_record_for

  def agent_belongs_to_workspace
    return if agent.blank? || workspace.blank?
    return if agent.workspace_id == workspace_id

    errors.add(:agent, "must belong to the current workspace")
  end
end
```

**Note on `compacted` as session status**: The PRD mentions `compacted` as a session status, but compaction is a message-level operation. A session with compacted messages is still `active`. Adding a `compacted` session status would confuse the state machine. Sessions have two states: `active` and `archived`.

### 3.2 Message

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  include WorkspaceScoped

  acts_as_message chat: :session, tool_calls: :tool_calls, model: :model

  belongs_to :session
  has_many :tool_calls, dependent: :destroy

  scope :active, -> { where(compacted: [false, nil]) }
  scope :for_context, -> { active.order(:created_at) }
  scope :compacted, -> { where(compacted: true) }

  # Returns the content appropriate for context replay.
  # For media messages, returns the text description instead of raw media.
  # For regular messages, returns the content as-is.
  #
  # @return [String]
  def content_for_context
    return media_description if media_description.present?

    content.to_s
  end
end
```

---

## 4. Services

### 4.1 AgentRuntime

Drop-in replacement for `SimpleChatService`. Same constructor and `call()` interface so `ChatStreamJob` requires only a one-line swap.

```ruby
# app/services/agent_runtime.rb

# Core agent runtime: checks compaction threshold, builds context,
# and streams the LLM response.
#
# Replaces SimpleChatService. Designed for future extension with
# tools, memory injection, and budget enforcement.
class AgentRuntime
  COMPACTION_THRESHOLD = 0.75
  DEFAULT_PROVIDER = :openai_responses

  # @param session [Session]
  def initialize(session:)
    @session = session
    @agent = session.agent
  end

  # Streams a single assistant response for the given user message.
  #
  # Checks compaction threshold before each turn. If exceeded,
  # enqueues async compaction (does not block the current request).
  #
  # @param user_message [String]
  # @yieldparam chunk [RubyLLM::Chunk]
  # @return [RubyLLM::Message]
  def call(user_message, &stream_block)
    trigger_compaction_if_needed

    context = ContextBuilder.new(session: @session, agent: @agent).build

    provider = @agent.resolved_provider || AgentRuntime::DEFAULT_PROVIDER

    @session
      .with_model(@agent.model_id, provider:)
      .with_instructions(context[:system_prompt])
      .with_temperature(@agent.temperature || 0.7)
      .ask(user_message, &stream_block)
  end

  private

  # Enqueues async compaction if the context window is above threshold.
  # Does not block the current request — compaction runs in a GoodJob worker.
  #
  # @return [void]
  def trigger_compaction_if_needed
    return unless @session.context_window_usage >= COMPACTION_THRESHOLD

    CompactionJob.perform_later(
      @session.id,
      workspace_id: @session.workspace_id
    )
  end
end
```

### 4.2 ContextBuilder

Assembles the full LLM context: system prompt (from `PromptBuilder`) + session summary + active messages.

```ruby
# app/services/context_builder.rb

# Assembles the complete context that the LLM receives for a session.
#
# Components:
#   1. System prompt (from PromptBuilder: instructions + soul + identity)
#   2. Session summary (from prior compactions, if any)
#   3. Active messages (non-compacted, chronological — managed by acts_as_chat)
class ContextBuilder
  # @param session [Session]
  # @param agent [Agent]
  def initialize(session:, agent: session.agent)
    @session = session
    @agent = agent
  end

  # @return [Hash] { system_prompt:, active_message_count:, estimated_tokens: }
  def build
    prompt_parts = [PromptBuilder.new(@agent).build]

    if @session.summary.present?
      prompt_parts << "## Previous Context\n\n#{@session.summary}"
    end

    {
      system_prompt: prompt_parts.compact.join("\n\n"),
      active_message_count: @session.context_messages.count,
      estimated_tokens: @session.estimated_context_tokens
    }
  end
end
```

### 4.3 CompactionService

Summarizes old messages and flags them as compacted. Designed to run inside a GoodJob worker (not in-request).

```ruby
# app/services/compaction_service.rb

# Summarizes old conversation messages and flags them as compacted.
#
# Preserves the most recent messages (PRESERVE_RECENT) and generates
# a summary of older messages via a secondary LLM call. The summary
# is appended to the session record (not a synthetic message).
#
# Must run in a background job — the LLM summarization call takes
# 2-30+ seconds and must not block Falcon's fiber reactor.
class CompactionService
  PRESERVE_RECENT = 10
  DEFAULT_SUMMARY_MODEL = "gpt-4o-mini"

  PROTECTED_PATTERNS = [
    /```[\s\S]+?```/,              # Code blocks
    /error|exception|fail/i,       # Error context
    /decision:|decided:|agreed:/i  # Key decisions
  ].freeze

  # @param session [Session]
  def initialize(session)
    @session = session
    @agent = session.agent
  end

  # Runs compaction. Idempotent — safe to call multiple times.
  #
  # @return [Hash] { compacted: true/false, reason: String, messages_compacted: Integer }
  def compact!
    active = @session.messages.for_context.to_a
    return { compacted: false, reason: "too_few_messages" } if active.size <= PRESERVE_RECENT

    to_compact = active[0...-PRESERVE_RECENT]
    preserved_facts = extract_preserved_content(to_compact)

    summary = generate_summary(to_compact, preserved_facts)
    return { compacted: false, reason: "summary_failed" } if summary.blank?

    ActiveRecord::Base.transaction do
      Message.where(id: to_compact.map(&:id)).update_all(compacted: true)
      combined = [@session.summary, summary].compact.join("\n\n---\n\n")
      @session.update!(summary: combined)
    end

    { compacted: true, reason: "success", messages_compacted: to_compact.size }
  rescue => e
    Rails.logger.error "[Compaction] Failed for session #{@session.id}: #{e.message}"
    { compacted: false, reason: "error: #{e.message}" }
  end

  private

  # @return [String]
  def compaction_model
    @agent.params&.dig("compaction_model") || @agent.model_id || DEFAULT_SUMMARY_MODEL
  end

  # @param messages [Array<Message>]
  # @param preserved_facts [String]
  # @return [String, nil]
  def generate_summary(messages, preserved_facts)
    prior_context = if @session.summary.present?
                      "PRIOR SUMMARY (incorporate and refine, do not discard):\n#{@session.summary}\n\n"
                    else
                      ""
                    end

    prompt = <<~PROMPT
      Summarize this conversation segment concisely. Preserve:
      - Key decisions and their rationale
      - Specific facts, numbers, file paths, error messages
      - User preferences and instructions
      - Tool call results that informed decisions
      Discard greetings, acknowledgments, and verbose explanations.

      #{prior_context}#{preserved_facts}
      Conversation to summarize:
      #{format_messages(messages)}
    PROMPT

    response = RubyLLM.chat(model: compaction_model)
                      .with_temperature(0.1)
                      .ask(prompt)
    response.content
  end

  # Formats messages for the compaction prompt.
  #
  # Each message is passed through MessageSummarizer: short messages
  # are included verbatim, long messages are condensed to ~400 chars
  # preserving key facts. Media messages use their text description
  # instead of raw binary/base64 content.
  #
  # @param messages [Array<Message>]
  # @return [String]
  def format_messages(messages)
    model = compaction_model
    messages.map do |m|
      text = MessageSummarizer.call(m.content_for_context, model:)
      "[#{m.role}] #{text}"
    end.join("\n")
  end

  # @param messages [Array<Message>]
  # @return [String]
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

---

## 5. Background Jobs

### 5.1 CompactionJob

```ruby
# app/jobs/compaction_job.rb

# Runs session compaction asynchronously.
#
# GoodJob concurrency controls ensure at most one compaction
# runs per session at a time — no advisory locks needed.
class CompactionJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :default

  # Prevent concurrent compaction on the same session.
  good_job_control_concurrency_with(
    perform_limit: 1,
    key: -> { "compaction_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [String] UUIDv7
  # @param workspace_id [String] UUIDv7 (for WorkspaceScopedJob)
  def perform(session_id, workspace_id:)
    session = Session.find(session_id)
    result = CompactionService.new(session).compact!

    Rails.logger.info(
      "[Compaction] session=#{session_id} " \
      "compacted=#{result[:compacted]} reason=#{result[:reason]} " \
      "messages_compacted=#{result[:messages_compacted] || 0}"
    )
  end
end
```

### 5.2 ArchiveStaleSessionsJob

```ruby
# app/jobs/archive_stale_sessions_job.rb

# Archives sessions that have been inactive for more than 7 days.
#
# Runs as a GoodJob cron job (daily). Archived sessions are searchable
# via the debug UI but not loaded into new LLM contexts.
class ArchiveStaleSessionsJob < ApplicationJob
  queue_as :default

  STALE_THRESHOLD = 7.days

  def perform
    sessions = Session.stale(STALE_THRESHOLD.ago)
    count = 0

    sessions.find_each do |session|
      # Generate a final summary asynchronously if needed
      if session.summary.blank? && session.messages.active.any?
        CompactionJob.perform_later(session.id, workspace_id: session.workspace_id)
      end

      session.archive!
      count += 1
    end

    Rails.logger.info "[ArchiveStale] Archived #{count} sessions"
  end
end
```

### 5.3 GoodJob Cron Registration

```ruby
# config/initializers/good_job.rb (add to existing config)
Rails.application.configure do
  config.good_job.cron = {
    archive_stale_sessions: {
      cron: "0 3 * * *",  # Daily at 3 AM
      class: "ArchiveStaleSessionsJob",
      description: "Archive sessions inactive for >7 days"
    }
  }
end
```

---

## 6. ChatStreamJob Update

One-line swap from `SimpleChatService` to `AgentRuntime`:

```ruby
# app/jobs/chat_stream_job.rb (change in perform method)

# Before:
# service = SimpleChatService.new(session: session)

# After:
service = AgentRuntime.new(session: session)
```

The rest of `ChatStreamJob` remains unchanged — `AgentRuntime` has the same `call(user_message, &stream_block)` interface.

---

## 7. ChatController Update

Include session summary in the chat response for context continuity:

```ruby
# app/controllers/api/v1/chat_controller.rb
def show
  agent = default_agent
  session = Session.resolve(agent: agent, gateway: "web")

  render json: {
    session_id: session.id,
    agent: { slug: agent.slug, name: agent.name },
    session_summary: session.summary,  # NEW
    context_window_usage: session.context_window_usage.round(2),  # NEW
    messages: session.messages
      .where(role: %w[user assistant system])
      .where(compacted: [false, nil])  # Only active messages
      .order(:created_at)
      .map { |m| message_json(m) }
  }
end
```

---

## 8. Implementation Phases

### Phase 1: Database + Models (independently testable)
1. Migration: compaction columns on messages (compacted, importance, partial index)
2. Migration: session management columns (summary, title, context_data, started_at, ended_at)
3. Message model: `active`, `for_context`, `compacted` scopes
4. Session model: `context_messages` association, `active_context_tokens`, `estimated_context_tokens`, `context_window_size`, `context_window_usage`, `stale` scope, `archive!`
5. **Spike**: Verify `acts_as_chat messages: :context_messages` works with ruby_llm. Test that `session.chat.ask()` only sends non-compacted messages.

### Phase 2: Services (depends on Phase 1)
1. `ContextBuilder` (simpler, testable first)
2. `CompactionService` (depends on message scopes)
3. `AgentRuntime` (composes the above)
4. Tests for all three services

### Phase 3: Jobs + Integration (depends on Phase 2)
1. `CompactionJob` with GoodJob concurrency controls
2. `ArchiveStaleSessionsJob` + GoodJob cron config
3. Update `ChatStreamJob` to use `AgentRuntime`
4. Update `ChatController#show` to include summary + context usage
5. Integration tests

---

## 9. Edge Cases & Error Handling

| Scenario | Handling |
|----------|---------|
| Compaction LLM call fails | Log error with classification (timeout, 4xx, 5xx, summary_failed). Session continues uncompacted. No user-facing error. |
| Concurrent messages near threshold | GoodJob `perform_limit: 1` prevents overlapping compaction. Only one job runs per session. Second enqueue is deduplicated. |
| Context still exceeds limit after compaction | Emergency: `AgentRuntime` truncates oldest active messages until under 90% budget. Logs warning for observability. |
| Session rotation (future) | Archive old session (transaction: status → archived, ended_at set), create new active session. `create_or_find_by!` handles race. |
| Model not in registry | `context_window_size` falls back to 128,000 tokens. |
| BYOK user without OpenAI | Compaction model falls back to agent's configured model. If that also fails, compaction is skipped. |
| Message with nil content | `content_for_context` returns `""` via `.to_s`. `MessageSummarizer` returns blank strings as-is. |
| Very long user message (50k+ chars) | `MessageSummarizer` condenses to ~400 chars for the compaction prompt, preserving key facts. Original is retained in `content` for debug tools. |
| Image/media message | On the original turn, the model sees the image. Post-processing stores a text description in `media_description`. All subsequent context replays and compaction use the description, not the binary. |
| `MessageSummarizer` LLM call fails | Falls back to `text.truncate(500)`. Compaction continues with degraded but functional summaries. |
| Multiple images in one message | `media_description` describes all images. Content block structure is preserved in `content_raw` for debug inspection. |

---

## 10. Performance Considerations

- **Partial index** on messages (`WHERE compacted = false`): orders of magnitude smaller than full index. Only active messages are indexed.
- **`update_all` for bulk compaction**: single SQL UPDATE, not N individual `update!` calls.
- **Token estimation via char/4**: no external HTTP calls, fiber-safe. Accurate counts deferred to post-response metadata update.
- **Compaction is async**: never blocks user requests. 25% context buffer absorbs one turn while compaction runs.
- **`find_each` in ArchiveStaleSessionsJob**: batched loading, no memory spikes on large datasets.

---

## 11. Verification Checklist

1. `bin/rails db:migrate` succeeds — new columns on messages and sessions
2. `Message.active` returns only non-compacted messages
3. `Session#estimated_context_tokens` returns reasonable estimate
4. `Session#context_window_usage` triggers at 0.75 threshold
5. `CompactionService.new(session).compact!` summarizes and flags messages
6. Summary is appended (not overwritten) on subsequent compactions
7. `CompactionJob` respects concurrency limit — only one per session
8. `ArchiveStaleSessionsJob` archives sessions inactive >7 days
9. `AgentRuntime` is a drop-in for `SimpleChatService` — chat still works
10. `ChatController#show` returns only active messages + summary
11. **Spike passes**: `acts_as_chat messages: :context_messages` sends only non-compacted messages to LLM
12. `MessageSummarizer.call(short_text)` returns text verbatim
13. `MessageSummarizer.call(long_text)` returns condensed version (~400 chars) preserving key facts
14. Media messages use `media_description` in `content_for_context`, not raw content
15. Compaction of a session with a 50k-char message produces a useful summary (not truncated garbage)
16. `bundle exec rails test` passes
17. `bundle exec rubocop` passes
18. `bundle exec brakeman --quiet` shows no critical issues
