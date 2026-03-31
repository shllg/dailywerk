---
type: rfc
title: Voice Message Processing
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/02-integrations-and-channels
  - prd/03-agentic-system
depends_on:
  - rfc/2026-03-29-simple-chat-conversation
  - rfc/2026-03-31-agent-configuration
  - rfc/2026-03-31-agent-session-management
  - rfc/2026-03-30-messaging-gateway-and-bridge-protocol
phase: 2
---

# RFC: Voice Message Processing

## Context

Voice messages are the dominant input modality on Signal, Telegram, and WhatsApp. All three platforms encode voice as OGG/Opus. The [bridge protocol RFC](2026-03-30-messaging-gateway-and-bridge-protocol.md) already carries `attachments[]` with `mime_type`, `download_url`, `byte_size` on inbound events, and specifies that Core fetches and stores attachments from the bridge's temporary URL (§Attachments). No code currently handles attachments — this is greenfield.

ruby_llm v1.14+ has built-in `RubyLLM.transcribe()` supporting OGG, MP3, WAV, WebM, M4A. The [session management RFC](2026-03-31-agent-session-management.md) already defines `media_description` on messages and `content_for_context` (D8), plus `MessageSummarizer` for long text condensation (D7). Voice messages slot into these patterns naturally: transcribe → store transcript as `content` → treat like any text message for compaction.

### What This RFC Covers

- Database migration adding media columns to messages
- `VoiceMessageProcessor` service: download → store → transcribe → update → trigger agent
- `TranscriptionService` wrapping `RubyLLM.transcribe()` with configurable model
- `WorkspaceStorageService` for S3 with per-workspace SSE-C encryption (reusable for images/files)
- `VoiceProcessingJob` background job with retry and concurrency controls
- `ChatStreamJob` / `AgentRuntime` integration for pre-existing user messages
- Frontend `VoiceMessageBubble` with pending/completed/failed states
- Compaction integration via existing `media_description` and `MessageSummarizer` patterns

### What This RFC Does NOT Cover

- Image/file attachments (future RFC — same patterns, different processing)
- Voice recording from the web UI (future — same pipeline once recorded)
- Text-to-speech for agent responses (future — outbound media)
- Real-time voice conversations / streaming STT (future — Gemini Live API)
- Bridge inbound webhook handler (see [bridge protocol RFC](2026-03-30-messaging-gateway-and-bridge-protocol.md))
- Contact authorization (see bridge protocol RFC §Sender Authorization)

---

## 1. Voice Message Formats by Platform

All platforms standardize on OGG/Opus — `RubyLLM.transcribe()` handles all of them.

| Platform | Container | Codec | MIME Type | Max Size | Typical Size |
|----------|-----------|-------|-----------|----------|-------------|
| Signal | OGG | Opus (CBR) | `audio/ogg; codecs=opus` | 100 MB | ~200-300 KB/min |
| Telegram | OGG | Opus | `audio/ogg` | 50 MB (voice ≤1 MB) | ~200-300 KB/min |
| WhatsApp | OGG | Opus | `audio/ogg` | 16 MB | ~200-300 KB/min |

---

## 2. Transcription Model Selection

The transcription model is **configurable per agent** via `agent.params["transcription_model"]`, following the same pattern as the compaction model in the [session management RFC](2026-03-31-agent-session-management.md).

### Landscape (March 2026)

| Model | Cost | Accuracy (WER) | Via ruby_llm? | Notes |
|-------|------|-----------------|---------------|-------|
| **gpt-4o-mini-transcribe** | $0.003/min | ~4-5% | Yes | **Default.** OpenAI's current recommendation. Cheapest via ruby_llm. |
| gpt-4o-transcribe | $0.006/min | ~3-4% | Yes | Better for technical speech, noisy audio. |
| gpt-4o-transcribe-diarize | $0.006/min | ~3-4% | Yes | Speaker identification. Useful for group voice notes. |
| Gemini 2.5 Flash (audio) | ~3x text token rate | ~3% | No | Multimodal — different API path. Future option when ruby_llm adds support. |
| ElevenLabs Scribe v2 | varies | 2.3% (best) | No | Separate API, not in ruby_llm. |
| Anthropic Claude | N/A | N/A | N/A | **No STT API exists.** |
| OpenRouter | N/A | N/A | N/A | **Doesn't proxy transcription endpoints.** |

### Why `gpt-4o-mini-transcribe` as default

- Cheapest option that works via `RubyLLM.transcribe()` — zero extra gems
- OpenAI recommends it over `gpt-4o-transcribe` for general use
- Good enough accuracy for conversational voice messages
- BYOK users with OpenAI keys get it automatically
- Future: when ruby_llm adds Gemini audio, the configurable field means zero code changes

```ruby
def transcription_model
  @agent.params&.dig("transcription_model") || "gpt-4o-mini-transcribe"
end
```

---

## 3. Design Decisions

### D1: Columns on messages, not a separate attachments table

Voice messages are 1:1 with message rows. A join table adds query overhead to every context build and compaction query for no structural gain. The bridge protocol normalizes voice into a single attachment per inbound event.

Six new columns on `messages`:

| Column | Type | Purpose |
|--------|------|---------|
| `media_type` | string, nullable | `"voice"`, `"image"`, `"file"`, nil for text |
| `media_storage_key` | string, nullable | S3 key: `workspaces/{workspace_id}/voice/{message_id}.ogg` |
| `media_duration_seconds` | integer, nullable | From transcription result metadata |
| `media_mime_type` | string, nullable | Original MIME from bridge (`audio/ogg`) |
| `media_byte_size` | bigint, nullable | File size in bytes |
| `transcription_status` | string, nullable | `pending` / `completed` / `failed` |

`media_description` already exists from the [session management RFC](2026-03-31-agent-session-management.md) migration.

### D2: Single background job for the full pipeline

`VoiceProcessingJob` does: download from bridge → upload to S3 → transcribe → update message → trigger agent. One job (not three) because:

- Bridge `download_url` expires in 15 minutes — download can't be deferred
- Typical voice file is 200-300 KB — fast to process end-to-end
- Every step is idempotent on retry (deterministic S3 key, stateless transcription)
- Splitting into separate jobs adds inter-job coordination without improving reliability

### D3: Message exists immediately with placeholder

On inbound webhook receipt, the message is created with:
- `content: "[Transcribing voice message…]"`
- `transcription_status: "pending"`
- `media_type: "voice"`

Web UI renders a voice message bubble with a spinner. After transcription completes, ActionCable pushes `{ type: "transcription_complete", message_id, content }` and the SPA updates in-place.

Messenger channels (Signal, Telegram, WhatsApp) show nothing intermediate — the user sees only the agent's response after transcription succeeds.

### D4: `media_description` via heuristic, not LLM

No separate LLM call for the description. Generate it cheaply from the transcription result:

```ruby
"[Voice: #{duration}s] #{transcript.truncate(200)}"
```

The `MessageSummarizer` (session management RFC, D7) handles long transcripts during compaction the same as any long text message. The media_description is used by `content_for_context` during context replay.

### D5: Always store the audio file in S3

Cost is negligible (~300 KB/min, typical voice message 15-60s = 75-300 KB). Benefits:
- Retry failed transcriptions without re-downloading (bridge URL expires)
- Audit/compliance trail
- Future voice playback in web UI
- Re-transcription with improved models

Audio files stored at: `workspaces/{workspace_id}/voice/{message_id}.ogg`

Per-workspace SSE-C encryption applied (same infrastructure as vault files).

### D6: ChatStreamJob gets `existing_message_id:` parameter

Voice messages already exist as a persisted Message when the agent needs to respond. `ChatStreamJob` / `AgentRuntime` needs a code path to respond to an existing user message without creating a duplicate. When `existing_message_id:` is set, skip user message creation and only generate the assistant turn.

This also enables future use cases: image messages, file messages, edited messages — any scenario where the user message is pre-created before agent processing.

---

## 4. Database Schema

### Migration: Add Media Columns to Messages

```ruby
# db/migrate/TIMESTAMP_add_media_columns_to_messages.rb
class AddMediaColumnsToMessages < ActiveRecord::Migration[8.1]
  def change
    safety_assured do
      change_table :messages, bulk: true do |t|
        t.string  :media_type                    # voice, image, file — nil for text
        t.string  :media_storage_key             # S3 key for stored media
        t.integer :media_duration_seconds        # Audio/video duration
        t.string  :media_mime_type               # Original MIME type from bridge
        t.bigint  :media_byte_size               # File size in bytes
        t.string  :transcription_status          # pending, completed, failed
      end
    end

    # Fast lookup for media messages (sparse — most messages are text)
    add_index :messages, :media_type,
              where: "media_type IS NOT NULL",
              name: "idx_messages_media_type"

    # Monitor pending transcriptions
    add_index :messages, :transcription_status,
              where: "transcription_status = 'pending'",
              name: "idx_messages_pending_transcription"
  end
end
```

All columns are nullable — existing text messages are unaffected. Safe with `strong_migrations`.

---

## 5. Model Changes

```ruby
# app/models/message.rb (additions)

validates :media_type, inclusion: { in: %w[voice image file] }, allow_nil: true
validates :transcription_status, inclusion: { in: %w[pending completed failed] }, allow_nil: true

scope :voice, -> { where(media_type: "voice") }
scope :pending_transcription, -> { where(transcription_status: "pending") }
scope :failed_transcription, -> { where(transcription_status: "failed") }

# @return [Boolean]
def voice?
  media_type == "voice"
end

# @return [Boolean]
def transcription_pending?
  transcription_status == "pending"
end

# @return [Boolean]
def transcription_failed?
  transcription_status == "failed"
end

# @return [Boolean]
def has_media?
  media_type.present?
end
```

The `content_for_context` method already exists from the session management RFC — it returns `media_description` when present, falling back to `content.to_s`. No changes needed.

---

## 6. Services

### 6.1 WorkspaceStorageService

Reusable S3 service with per-workspace SSE-C encryption. Used for voice files now, images/files later.

```ruby
# app/services/workspace_storage_service.rb

# S3 storage with per-workspace SSE-C encryption.
#
# Provides put/get/delete operations scoped to a workspace's
# storage prefix with automatic encryption key handling.
# Reusable for voice files, images, attachments, and vault data.
class WorkspaceStorageService
  # @param workspace [Workspace]
  def initialize(workspace)
    @workspace = workspace
  end

  # Uploads a file to S3 with workspace-scoped path and encryption.
  #
  # @param key [String] relative path within workspace prefix
  # @param body [String, IO] file content
  # @param content_type [String] MIME type
  # @return [String] the full S3 key
  def put(key:, body:, content_type:)
    full_key = workspace_key(key)
    s3_client.put_object(
      bucket: bucket,
      key: full_key,
      body:,
      content_type:,
      **sse_c_params
    )
    full_key
  end

  # Downloads a file from S3.
  #
  # @param key [String] relative path within workspace prefix
  # @return [String] file content
  def get(key:)
    s3_client.get_object(
      bucket: bucket,
      key: workspace_key(key),
      **sse_c_params
    ).body.read
  end

  # Generates a deterministic S3 key for voice media.
  #
  # @param message_id [String] UUIDv7
  # @param extension [String] file extension
  # @return [String] relative key
  def voice_key(message_id, extension = "ogg")
    "voice/#{message_id}.#{extension}"
  end

  private

  def workspace_key(relative_key)
    "workspaces/#{@workspace.id}/#{relative_key}"
  end

  def sse_c_params
    key = @workspace.encryption_key
    return {} unless key

    {
      sse_customer_algorithm: "AES256",
      sse_customer_key: key,
      sse_customer_key_md5: Digest::MD5.base64digest(key)
    }
  end

  def s3_client
    @s3_client ||= Aws::S3::Client.new(
      region: Rails.application.config.x.s3_region,
      endpoint: Rails.application.config.x.s3_endpoint,
      credentials: Aws::Credentials.new(
        Rails.application.credentials.dig(:s3, :access_key_id),
        Rails.application.credentials.dig(:s3, :secret_access_key)
      )
    )
  end

  def bucket
    Rails.application.config.x.s3_bucket
  end
end
```

### 6.2 TranscriptionService

Thin wrapper around `RubyLLM.transcribe()` with configurable model and error handling.

```ruby
# app/services/transcription_service.rb

# Transcribes audio using RubyLLM's built-in transcription API.
#
# Wraps RubyLLM.transcribe() with model selection, error handling,
# and structured result extraction.
class TranscriptionService
  DEFAULT_MODEL = "gpt-4o-mini-transcribe"

  Result = Data.define(:text, :duration_seconds, :language, :model)

  # @param audio_file [Tempfile, IO] audio data
  # @param model [String] transcription model ID
  # @param language [String, nil] ISO 639-1 language hint
  # @return [TranscriptionService::Result]
  def self.call(audio_file, model: DEFAULT_MODEL, language: nil)
    kwargs = { model: }
    kwargs[:language] = language if language.present?

    result = RubyLLM.transcribe(audio_file, **kwargs)

    Result.new(
      text: result.text,
      duration_seconds: extract_duration(result),
      language: result.respond_to?(:language) ? result.language : nil,
      model:
    )
  end

  # @param result [Object] RubyLLM transcription result
  # @return [Integer, nil]
  def self.extract_duration(result)
    if result.respond_to?(:segments) && result.segments.any?
      result.segments.last.end.ceil
    elsif result.respond_to?(:duration)
      result.duration.ceil
    end
  end
  private_class_method :extract_duration
end
```

### 6.3 VoiceMessageProcessor

Orchestrator service called by `VoiceProcessingJob`. Handles the full pipeline: download → store → transcribe → update → trigger agent.

```ruby
# app/services/voice_message_processor.rb

# Processes a voice message: downloads audio from bridge, stores in S3,
# transcribes via LLM, updates the message record, and triggers the agent.
#
# Called by VoiceProcessingJob. Each step is idempotent on retry.
class VoiceMessageProcessor
  # @param message [Message] message with transcription_status: "pending"
  # @param download_url [String] bridge media URL (expires in 15 min)
  # @param bridge_api_key [String] bearer token for bridge download
  def initialize(message:, download_url:, bridge_api_key:)
    @message = message
    @download_url = download_url
    @bridge_api_key = bridge_api_key
    @workspace = message.workspace
    @agent = message.session.agent
  end

  # Runs the full processing pipeline.
  #
  # @return [Hash] { status:, transcript:, duration: }
  def call
    audio_data = download_audio
    store_audio(audio_data)
    result = transcribe(audio_data)
    update_message(result)
    record_cost(result)
    broadcast_completion(result)
    trigger_agent(result)

    { status: "completed", transcript: result.text, duration: result.duration_seconds }
  rescue RubyLLM::BadRequestError => e
    # Corrupt/unreadable audio — don't retry
    mark_failed("Transcription rejected: #{e.message}")
    raise # Re-raise for discard_on in job
  rescue => e
    mark_failed("Processing error: #{e.message}")
    raise # Re-raise for retry in job
  end

  private

  def download_audio
    response = Faraday.get(@download_url) do |req|
      req.headers["Authorization"] = "Bearer #{@bridge_api_key}"
      req.options.timeout = 30
    end

    raise "Bridge download failed: #{response.status}" unless response.success?

    response.body
  end

  def store_audio(audio_data)
    storage = WorkspaceStorageService.new(@workspace)
    key = storage.voice_key(@message.id)

    storage.put(
      key:,
      body: audio_data,
      content_type: @message.media_mime_type || "audio/ogg"
    )

    @message.update!(media_storage_key: "voice/#{@message.id}.ogg")
  end

  def transcribe(audio_data)
    # Write to Tempfile for RubyLLM (needs a file-like object)
    file = Tempfile.new(["voice", ".ogg"])
    file.binmode
    file.write(audio_data)
    file.rewind

    model = @agent.params&.dig("transcription_model") || TranscriptionService::DEFAULT_MODEL
    TranscriptionService.call(file, model:)
  ensure
    file&.close!
  end

  def update_message(result)
    @message.update!(
      content: result.text,
      transcription_status: "completed",
      media_duration_seconds: result.duration_seconds,
      media_description: build_description(result)
    )
  end

  # Heuristic description — no LLM call needed.
  def build_description(result)
    duration = result.duration_seconds || 0
    "[Voice: #{duration}s] #{result.text.truncate(200)}"
  end

  def record_cost(result)
    return unless result.duration_seconds

    minutes = result.duration_seconds / 60.0
    cost_usd = minutes * cost_per_minute(result.model)

    # TODO: Record in usage_records when billing ships
    Rails.logger.info(
      "[VoiceProcessing] message=#{@message.id} " \
      "model=#{result.model} duration=#{result.duration_seconds}s " \
      "cost_usd=#{cost_usd.round(6)}"
    )
  end

  def cost_per_minute(model)
    case model
    when "gpt-4o-mini-transcribe" then 0.003
    when "gpt-4o-transcribe", "gpt-4o-transcribe-diarize" then 0.006
    when "whisper-1" then 0.006
    else 0.006 # Conservative default
    end
  end

  def broadcast_completion(result)
    ActionCable.server.broadcast("session_#{@message.session_id}", {
      type: "transcription_complete",
      message_id: @message.id,
      content: result.text,
      duration_seconds: result.duration_seconds
    })
  end

  def trigger_agent(result)
    ChatStreamJob.perform_later(
      @message.session_id,
      result.text,
      workspace_id: @workspace.id,
      existing_message_id: @message.id
    )
  end

  def mark_failed(reason)
    @message.update!(
      content: "[Voice message — transcription failed]",
      transcription_status: "failed"
    )

    ActionCable.server.broadcast("session_#{@message.session_id}", {
      type: "transcription_failed",
      message_id: @message.id,
      reason: reason.truncate(200)
    })
  end
end
```

---

## 7. Background Job

```ruby
# app/jobs/voice_processing_job.rb

# Downloads, stores, and transcribes a voice message.
#
# Retries 3 times with polynomial backoff for transient failures.
# Discards on RubyLLM::BadRequestError (corrupt/unreadable audio).
# Concurrency: one job per message (prevents duplicate processing).
class VoiceProcessingJob < ApplicationJob
  include WorkspaceScopedJob

  queue_as :llm

  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  discard_on RubyLLM::BadRequestError
  discard_on ActiveRecord::RecordNotFound

  good_job_control_concurrency_with(
    perform_limit: 1,
    key: -> { "voice_#{arguments.first}" }  # message_id
  )

  # @param message_id [String] UUIDv7
  # @param download_url [String] bridge media URL
  # @param bridge_api_key [String] bearer token for download
  # @param workspace_id [String] UUIDv7 (for WorkspaceScopedJob)
  def perform(message_id, download_url:, bridge_api_key:, workspace_id:)
    message = Message.find(message_id)

    VoiceMessageProcessor.new(
      message:,
      download_url:,
      bridge_api_key:
    ).call
  end
end
```

---

## 8. ChatStreamJob Integration

`ChatStreamJob` needs a new `existing_message_id:` parameter. When set, the job skips user message creation and responds to the pre-existing message.

```ruby
# app/jobs/chat_stream_job.rb (updated perform signature)

def perform(session_id, user_message, workspace_id:, existing_message_id: nil)
  session = Session.find(session_id)

  service = AgentRuntime.new(session:)

  assistant_message = nil

  if existing_message_id
    # Voice/media message: user message already exists, just generate response
    response = service.respond(&streaming_block(session, assistant_message))
  else
    # Text message: create user message and generate response
    response = service.call(user_message, &streaming_block(session, assistant_message))
  end

  # ... rest of existing complete/error handling
end
```

`AgentRuntime#respond` is a new method that generates an assistant response for the most recent user message in the session, without creating a new user message. It reuses the same compaction check → context build → ask flow.

```ruby
# app/services/agent_runtime.rb (addition)

# Generates an assistant response for the most recent user message
# in the session. Used when the user message was pre-created
# (voice messages, media messages, edited messages).
#
# @yieldparam chunk [RubyLLM::Chunk]
# @return [RubyLLM::Message]
def respond(&stream_block)
  trigger_compaction_if_needed

  context = ContextBuilder.new(session: @session, agent: @agent).build
  provider = @agent.resolved_provider || SimpleChatService::PROVIDER

  # Ask with empty string — acts_as_chat sees the existing user message
  # in the session and generates only the assistant response.
  @session
    .with_model(@agent.model_id, provider:)
    .with_instructions(context[:system_prompt])
    .with_temperature(@agent.temperature || 0.7)
    .ask("", &stream_block)
end
```

**Spike required**: Verify that `session.ask("")` with an existing user message in the session generates only the assistant turn. If ruby_llm creates a blank user message, an alternative approach is needed (e.g., directly calling the provider API via ruby_llm's lower-level interface).

---

## 9. Inbound Webhook Integration

The bridge inbound handler (from [bridge protocol RFC](2026-03-30-messaging-gateway-and-bridge-protocol.md)) detects voice messages and branches the processing:

```ruby
# In the inbound event processor (future bridge controller):

def process_inbound_message(event, session)
  attachment = event.dig("message", "attachments")&.first

  if voice_attachment?(attachment)
    message = create_voice_placeholder(session, attachment)
    enqueue_voice_processing(message, attachment)
  else
    # Text message — existing ChatStreamJob flow
    ChatStreamJob.perform_later(session.id, event.dig("message", "text"), workspace_id:)
  end
end

def voice_attachment?(attachment)
  return false unless attachment

  attachment["mime_type"]&.start_with?("audio/")
end

def create_voice_placeholder(session, attachment)
  session.messages.create!(
    role: "user",
    content: "[Transcribing voice message…]",
    workspace: session.workspace,
    media_type: "voice",
    media_mime_type: attachment["mime_type"],
    media_byte_size: attachment["byte_size"],
    transcription_status: "pending"
  )
end

def enqueue_voice_processing(message, attachment)
  VoiceProcessingJob.perform_later(
    message.id,
    download_url: attachment["download_url"],
    bridge_api_key: @bridge.api_key,
    workspace_id: message.workspace_id
  )
end
```

---

## 10. Compaction Integration

After transcription, voice messages are **indistinguishable from text messages** for compaction:

- `content` = full transcript (what the LLM sees in active context)
- `media_description` = heuristic summary for compaction context replay: `"[Voice: 15s] user discusses meeting tomorrow at 2pm"`
- `content_for_context` (from session management RFC D8) returns `media_description` when present

The `CompactionService#format_messages` already calls `MessageSummarizer.call(m.content_for_context)`, which handles long transcripts the same as any long text message. **No changes needed to the compaction pipeline.**

```
Voice message lifecycle:
  1. Inbound: content="[Transcribing...]", transcription_status="pending"
  2. Transcribed: content="full transcript text", media_description="[Voice: 15s] summary"
  3. In active context: LLM sees full transcript via content
  4. During compaction: MessageSummarizer condenses the transcript
  5. After compaction: content_for_context returns media_description
  6. Audio file remains in S3 (viewable via debug tools)
```

---

## 11. Frontend

### VoiceMessageBubble Component

```
VoiceMessageBubble
  ├─ [pending] Waveform icon + "Transcribing..." spinner + duration (if known)
  ├─ [completed] Transcript text + duration badge + 🎤 icon
  └─ [failed] "Voice message — transcription failed" in muted style + retry hint
```

### ActionCable Events

The `useActionCableChat` hook handles two new event types:

```typescript
// transcription_complete → update message content in-place
case "transcription_complete":
  updateMessage(event.message_id, {
    content: event.content,
    transcription_status: "completed",
    media_duration_seconds: event.duration_seconds,
  })
  break

// transcription_failed → show failed state
case "transcription_failed":
  updateMessage(event.message_id, {
    content: "[Voice message — transcription failed]",
    transcription_status: "failed",
  })
  break
```

### Message Type Updates

```typescript
// frontend/src/types/chat.ts (additions)
export interface Message {
  // ... existing fields
  media_type: 'voice' | 'image' | 'file' | null
  transcription_status: 'pending' | 'completed' | 'failed' | null
  media_duration_seconds: number | null
}
```

---

## 12. Implementation Phases

### Phase 1: Database + Model
1. Migration: 6 media columns + partial indexes
2. Message model: scopes, predicates, validations
3. Tests for model changes

### Phase 2: Storage Service
1. `WorkspaceStorageService` with SSE-C
2. Test against RustFS in docker-compose dev environment
3. **Spike**: Where does the workspace-level encryption key live? Options: (a) add `encryption_key_enc` column to `workspaces`, (b) reuse default vault's key. Option (a) is simplest.

### Phase 3: Transcription Pipeline
1. `TranscriptionService` wrapper
2. `VoiceMessageProcessor` orchestrator
3. `VoiceProcessingJob` with GoodJob retry + concurrency controls
4. **Spike**: Verify `RubyLLM.transcribe()` method signature — accepts Tempfile/IO/path? Returns what structure?
5. Tests with OGG fixture file

### Phase 4: Agent Integration
1. `ChatStreamJob` — add `existing_message_id:` parameter
2. `AgentRuntime#respond` — generate response for existing user message
3. **Spike**: Verify `session.ask("")` generates only the assistant turn when a user message already exists
4. ActionCable broadcast types
5. Integration tests

### Phase 5: Frontend
1. `VoiceMessageBubble` component (DaisyUI + Tailwind)
2. ActionCable event handling for `transcription_complete` / `transcription_failed`
3. `MessageBubble` routing by `media_type`
4. Message type updates

---

## 13. Edge Cases & Error Handling

| Scenario | Handling |
|----------|---------|
| Transcription API fails (timeout/5xx) | 3 retries with polynomial backoff. On final failure: `transcription_status: "failed"`, content: `"[Voice message — transcription failed]"`. Agent NOT triggered. Audio remains in S3 for manual retry. |
| Corrupt/unreadable audio (4xx) | `discard_on RubyLLM::BadRequestError` — no retry, immediate failure. |
| Bridge download_url expired | Retry within 15-min window. If expired on all attempts, fail permanently. |
| File > 25 MB (Whisper API limit) | Detect before transcription. Store in S3 anyway. Set `transcription_status: "failed"` with message: `"[Voice message too large for transcription]"`. Future: implement chunked transcription. |
| Concurrent voice messages in same session | Each gets its own `VoiceProcessingJob`. Agent triggered per-message. GoodJob `perform_limit: 1` per message_id prevents duplicate processing. |
| Voice message during compaction | Compaction uses `content_for_context` → `media_description`. No interaction with audio storage. |
| BYOK user without OpenAI | Transcription model falls back to agent's configured model. If no valid model for transcription, job fails and voice message shows as failed. |
| Empty/silent audio | Whisper returns empty string. Store as-is. Agent receives empty user message — likely responds with clarification request. |

---

## 14. Security Considerations

- **Audio stored encrypted**: Per-workspace SSE-C encryption in S3. Same security model as vault files.
- **Bridge download authenticated**: `VoiceProcessingJob` uses the bridge's bearer token for downloads. Token is passed as job argument (encrypted at rest by GoodJob/PG).
- **No raw audio in LLM context**: Only the text transcript reaches the LLM. Audio binary never enters the context window.
- **Workspace isolation**: All S3 keys prefixed with `workspaces/{workspace_id}/`. RLS on messages table provides defense-in-depth.
- **Tempfile cleanup**: `Tempfile` used for `RubyLLM.transcribe()` is explicitly closed and unlinked in `ensure` block.

---

## 15. Cost Considerations

| Voice Duration | Storage Cost (Hetzner) | Transcription Cost (gpt-4o-mini) |
|---------------|----------------------|--------------------------------|
| 15 seconds | ~0.001 cent | $0.00075 |
| 1 minute | ~0.004 cent | $0.003 |
| 5 minutes | ~0.02 cent | $0.015 |
| 1,000 messages/month (avg 30s) | ~2 cents total | ~$1.50 total |

Storage is negligible. Transcription is the primary cost. At 1,000 voice messages/month with average 30s duration, total transcription cost is ~$1.50/month.

---

## 16. Verification Checklist

1. Migration succeeds — 6 new columns on messages
2. `Message.voice` scope returns only voice messages
3. `WorkspaceStorageService` puts and gets files with SSE-C encryption (test against RustFS)
4. `TranscriptionService.call(ogg_file)` returns text + duration + language
5. `VoiceMessageProcessor` full pipeline: download → store → transcribe → update → trigger
6. `VoiceProcessingJob` respects `perform_limit: 1` per message
7. `VoiceProcessingJob` retries on transient errors, discards on 4xx
8. `ChatStreamJob` with `existing_message_id:` responds without creating duplicate user message
9. Compaction handles voice messages correctly — `media_description` used in context replay
10. ActionCable broadcasts `transcription_complete` and `transcription_failed`
11. Frontend: voice bubble shows pending → completed → failed states
12. Cost logged in `usage_records` (or Rails logger until billing ships)
13. Audio file persists in S3 after transcription
14. **Spike passes**: `RubyLLM.transcribe()` method signature verified
15. **Spike passes**: `session.ask("")` with existing user message works correctly
16. `bundle exec rails test` passes
17. `bundle exec rubocop` passes
18. `bundle exec brakeman --quiet` shows no critical issues
