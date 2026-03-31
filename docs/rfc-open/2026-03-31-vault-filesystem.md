---
type: rfc
title: Vault Filesystem — Obsidian-Compatible Knowledge Store
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/01-platform-and-infrastructure
  - prd/02-integrations-and-channels
  - prd/03-agentic-system
depends_on:
  - rfc/2026-03-30-workspace-isolation
phase: 2
---

# RFC: Vault Filesystem — Obsidian-Compatible Knowledge Store

## Context

DailyWerk's PRDs define a vault system where users store personal knowledge (diary entries, research notes, nutrition logs) as Obsidian-compatible markdown files, along with supporting attachments like images and PDFs. Agents read, write, search, and link this knowledge. The vault is the user's portable data layer — it survives agent deletion and is exportable.

This RFC implements the **foundation**: the workspace-scoped vault filesystem with S3 as the canonical store, local disk as the working copy, and PostgreSQL for metadata, search indexes, and the backlink graph.

### What This RFC Covers

- Database schema for vaults, vault_files, vault_chunks, vault_links (workspace-scoped, RLS)
- Vault lifecycle management (create, destroy, checkout from S3)
- File CRUD with path traversal and symlink protection
- S3 storage service with per-vault SSE-C encryption
- Markdown-aware chunking for hybrid search (pgvector + tsvector via RRF)
- Wikilink and embed parser for the backlink graph
- inotify-based file watcher (standalone process)
- Background jobs for indexing and S3 sync
- VaultTool for agent interaction
- Local dev (RustFS) and production (Hetzner Object Storage) configuration

### What This RFC Does NOT Cover (see companion RFCs)

- Obsidian Sync integration via obsidian-headless ([RFC: Obsidian Sync](./2026-03-31-obsidian-sync.md))
- File versioning, snapshots, backup/restore ([RFC: Vault Backup & Versioning](./2026-03-31-vault-backup-versioning.md))
- Vault dashboard/file browser in the frontend (future RFC)
- Multi-vault pricing and workspace plan limits (future RFC)

### PRD workspace_id Correction

[RFC 002: Workspace Isolation](../rfc-done/2026-03-30-workspace-isolation.md) moved all user-facing data from `user_id` to `workspace_id`. The PRD vault schemas ([01 SS5.6](../prd/01-platform-and-infrastructure.md#56-vault-tables)) still reference `user_id` — this is stale. This RFC uses `workspace_id` throughout, aligning with the workspace isolation model.

Corrected references:
- Disk paths: `/data/workspaces/{workspace_id}/vaults/{slug}/` (not `/data/vaults/{user_id}/`)
- S3 prefix: `workspaces/{workspace_id}/vaults/{slug}/` (not `vaults/{user_id}/`)
- RLS: `app.current_workspace_id` (not `app.current_user_id`)
- Queries: `workspace.vaults` (not `user.vaults`)

---

## 1. Prerequisites

- **Workspace isolation** implemented ([RFC 002](../rfc-done/2026-03-30-workspace-isolation.md)): `Current.workspace`, `WorkspaceScoped` concern, RLS via `app.current_workspace_id`
- **`aws-sdk-s3`** gem in Gemfile (already present, `required: false`)
- **RustFS** running in Docker Compose (already configured on port 9002, bucket `dailywerk-dev`)
- **`ruby_llm ~> 1.14`** for embedding generation (already in Gemfile)
- **`neighbor`** gem for pgvector integration (already in Gemfile)
- **`rb-inotify`** gem added to Gemfile for file watching

---

## 2. Obsidian File Format Reference

Agents must understand the Obsidian ecosystem to manage vaults effectively. This section documents what the system must parse, index, and preserve.

### 2.1 Supported File Formats

The vault stores persistent knowledge — markdown notes and supporting attachments (images, PDFs). Audio and video files are **not vault content** by design. Voice messages and media from messaging channels (Signal, Telegram, WhatsApp) belong in the session/message layer, not the vault. If a user places audio/video files in their Obsidian vault manually, they are preserved by sync but not indexed or promoted by the agent.

| Category | Extensions | Indexed | Chunked | Agent-Writable |
|----------|-----------|---------|---------|----------------|
| Markdown | `.md` | Yes | Yes | Yes |
| JSON Canvas | `.canvas` | Yes (links only) | No | No (Obsidian-managed) |
| Images | `.avif`, `.bmp`, `.gif`, `.jpeg`, `.jpg`, `.png`, `.svg`, `.webp` | Metadata only | No | Yes (attachments) |
| PDF | `.pdf` | Metadata only | No (future: PDF text extraction) | Yes (attachments) |
| Audio | `.flac`, `.m4a`, `.mp3`, `.ogg`, `.wav`, `.webm`, `.3gp` | No | No | No (sync-only) |
| Video | `.mkv`, `.mov`, `.mp4`, `.ogv`, `.webm` | No | No | No (sync-only) |

### 2.2 Obsidian-Flavored Markdown

Features the system must parse:

- **Wikilinks**: `[[Note Name]]`, `[[Note Name#Heading]]`, `[[Note Name|Display Text]]`, `[[Note Name#^block-id]]`
- **Embeds**: `![[Note Name]]`, `![[image.png]]`, `![[audio.mp3]]`, `![[file.pdf]]`
- **Tags**: `#tag`, `#nested/tag` (inline or in frontmatter `tags:` array)
- **Frontmatter**: YAML between `---` delimiters (title, date, tags, aliases, etc.)
- **Tables**: GFM-style pipe tables with header row, alignment row, and data rows
- **Callouts**: `> [!note]`, `> [!warning]`, etc.
- **Code blocks**: Fenced with language hints
- **Comments**: `%%hidden comment%%` (excluded from search)
- **Math**: `$inline$` and `$$block$$` (preserved, not parsed)

#### Pipes in Wikilinks Inside Tables — Critical

Obsidian's `|` serves double duty: table column separator AND wikilink alias separator. A wikilink with an alias inside a table cell **breaks the table** unless the pipe is escaped:

```markdown
<!-- BROKEN — the | in the wikilink is parsed as a column separator -->
| Topic | Link |
|-------|------|
| Setup | [[getting-started|Getting Started]] |

<!-- CORRECT — escaped pipe inside wikilink -->
| Topic | Link |
|-------|------|
| Setup | [[getting-started\|Getting Started]] |
```

This is a known Obsidian behavior. **Agent prompts MUST instruct the LLM to escape pipes in wikilink aliases when writing inside tables** (`\|` instead of `|`). Failure to do so produces corrupted markdown that renders incorrectly in Obsidian.

The `VaultLinkExtractor` must also handle escaped pipes when parsing wikilinks:

```ruby
# In VaultLinkExtractor, the regex must account for escaped pipes:
WIKILINK_REGEX = /(?<!!)\[\[([^\]|\\]+(?:\\.[^\]|\\]*)*)(?:(?:\||\\|)([^\]]*))?\]\]/
```

This applies to embeds with aliases too (`![[image.png\|300]]` for resized images inside tables).

### 2.3 Vault Structure — Configurable via `_dailywerk/` Folder

Vault structure is **not hardcoded**. Each vault contains a `_dailywerk/` folder with a vault guide that agents follow when placing files. The guide is editable by the user (in Obsidian or via the web UI) and travels with the vault via Obsidian Sync.

**Why `_dailywerk/` and not `.dailywerk/`**: Obsidian Sync does NOT sync dot-prefixed folders (except `.obsidian/`). Using underscore ensures the guide syncs to all devices and is visible in Obsidian's file explorer.

#### The `_dailywerk/` Folder

```
_dailywerk/
  README.md           ← Explains what this folder is and how it affects DailyWerk
  vault-guide.md      ← Structure rules the agent follows when placing files
  vault-analysis.md   ← Auto-generated analysis of the vault structure (for imported vaults)
```

**`_dailywerk/README.md`** — Always present. Explains the folder's purpose:

```markdown
# DailyWerk Configuration

This folder contains configuration that controls how your DailyWerk AI assistant
interacts with this vault. The files here affect how the agent places, organizes,
and navigates your notes.

## Files

- **vault-guide.md** — Structure rules the agent follows. Edit this to change how
  your agent organizes notes. You can edit it here in Obsidian or in the DailyWerk
  web dashboard.
- **vault-analysis.md** — Auto-generated analysis of your vault's structure. Created
  when you import an existing vault. Read-only reference.

## Important

- Do not delete this folder — DailyWerk will recreate it.
- Edits to vault-guide.md take effect on the agent's next interaction.
- This folder is synced by Obsidian Sync and indexed by DailyWerk.
```

**`_dailywerk/vault-guide.md`** — The agent reads this before every write operation. It defines where content goes. Editable via Obsidian or the web UI dashboard.

#### Default Vault Guide Template

New vaults (and vaults without a guide) get this default structure, inspired by PARA with numbered prefixes for sort order and temporal hierarchy for daily notes:

````markdown
---
description: Vault structure guide for DailyWerk agent
version: 1
---

# Vault Structure Guide

This document tells DailyWerk's AI agent how to organize files in this vault.
Edit it to match your preferred structure.

## Folder Structure

- `00 - Inbox/` — Unsorted captures, quick notes, items to be filed later
- `01 - Daily Notes/` — Daily journal entries, organized by month
  - `YYYY-MM/` — Month folder (e.g. `2026-03/`)
    - `Overview.md` — Listing of all daily notes in this month
    - `YYYY-MM-DD.md` — Individual daily note
  - `Overview.md` — Listing of all month overviews
- `01 - Note Summaries/` — Aggregated summaries from daily notes
  - `Weekly Notes/` — Weekly summaries
    - `YYYY-Www.md` — e.g. `2026-W13.md`
  - `Monthly Notes/` — Monthly summaries
    - `YYYY-MM.md` — e.g. `2026-03.md`
- `02 - Areas/` — Ongoing areas of responsibility
  - Organize by area name, e.g. `Work - ProjectName/`, `Private - Finance/`,
    `Health/`, `Meetings/`, `Research/`
- `03 - Resources/` — Reference material and knowledge base
  - Topics the user asked to save, research, or learn about
  - Organized by topic folder
- `04 - Archive/` — Completed or inactive material (lower search relevance)

## Placement Rules

When the agent creates a new note, it follows these rules:

1. **Daily notes** → `01 - Daily Notes/YYYY-MM/YYYY-MM-DD.md`
2. **Meeting notes** → `02 - Areas/Meetings/YYYY-MM-DD - {title}.md`
3. **Health/nutrition logs** → `02 - Areas/Health/nutrition/YYYY-MM-DD.md`
4. **Exercise logs** → `02 - Areas/Health/exercise/YYYY-MM-DD.md`
5. **Research on a topic** → `03 - Resources/{topic-slug}/` or `02 - Areas/Research/`
6. **Quick captures / unsorted** → `00 - Inbox/`
7. **Completed projects** → move to `04 - Archive/`
8. **Attachments** → same folder as the referencing note, or `attachments/` subfolder

## Naming Conventions

- Use lowercase-kebab-case for file names: `my-research-topic.md`
- Date-prefixed files use ISO format: `2026-03-31.md`, `2026-W13.md`
- Folder names use numbered prefixes for sort order: `00 -`, `01 -`, etc.

## Frontmatter Schemas

Define which YAML frontmatter fields each note type uses. The agent includes
these fields when creating notes of that type.

### Daily Notes

    date: YYYY-MM-DD
    tags: [daily]
    mood: null          # Ask user and record (scale 1-5 or free text)
    energy: null        # Optional energy level
    weather: null       # Optional

### Meeting Notes

    date: YYYY-MM-DD
    tags: [meeting]
    attendees: []
    action_items: []

### Research Notes

    date: YYYY-MM-DD
    tags: [research]
    topic: ""
    sources: []
    status: draft       # draft, review, complete

## Linking

- Always use `[[wikilinks]]` to connect related notes
- Prefer `[[note-name]]` over `[[note-name|alias]]` unless the display text adds clarity
- Daily notes should link to relevant area/resource notes
- Weekly/monthly summaries should link to their source daily notes

## Search Relevance

- `04 - Archive/` content has lower search weight (deprioritized in results)
- `_dailywerk/` content is excluded from user-facing search

## Agent Behaviors

Custom rules the agent follows when interacting with this vault.
Add new rules here via conversation (e.g. "remember my mood in daily notes").

- (No custom behaviors configured yet)
````

#### Imported Vaults — Structure Analysis

When a user imports an existing vault (connects Obsidian Sync to a vault with existing content), DailyWerk runs `VaultStructureAnalysisJob`:

1. Scans all files and folders
2. Identifies patterns: folder naming conventions, date formats, file organization style
3. Generates `_dailywerk/vault-analysis.md` describing what it found
4. Generates a draft `_dailywerk/vault-guide.md` that matches the existing structure
5. Notifies the user to review and edit the guide

This way the agent adapts to the user's existing organization rather than imposing the default.

#### Web UI Editing

The vault guide is stored as a file in the vault (synced, versioned, searchable), but it is also exposed via the DailyWerk web dashboard at `/settings/vaults/{id}/guide`. The dashboard provides:

- A text editor for the guide content
- A preview of how the agent will interpret the structure
- A "Reset to default" button

Edits via the dashboard write to the vault file directly. Obsidian Sync picks up the change.

### 2.4 Conversational Vault Configuration

Users configure their vault structure **through conversation** with the agent, not just through a settings UI. The vault guide is a living document that the agent updates based on user requests.

#### Example Flow

```
User: "Please ask me about my mood three times a day and remember it in the daily logs"

Agent thinks:
  1. This requires two changes:
     a. A recurring prompt (cron/scheduled job — separate system, out of scope)
     b. A vault guide update: daily notes frontmatter should include a "mood" field
  2. Read current vault guide
  3. Propose the change to the user

Agent: "I'll update your vault configuration to track mood in daily notes. Here's what I'll change:

  - **Daily Notes frontmatter**: Add `mood` field (scale 1-5 or free text)
  - **Daily Notes template**: Include a '## Mood' section

  For the three-times-a-day check-in, I'll set up a scheduled reminder
  (that's a separate setting — I'll handle it after the vault update).

  Should I go ahead?"

User: "Yes"

Agent: [calls VaultTool action: "update_guide" with the proposed changes]
       [separately creates the scheduled reminder — out of scope for this RFC]
```

#### What Can Be Configured Conversationally

| Category | Example User Request | Vault Guide Change |
|----------|---------------------|-------------------|
| **Frontmatter fields** | "Track mood in daily notes" | Add `mood` to Daily Notes frontmatter schema |
| **Folder structure** | "I want a separate folder for book notes" | Add `03 - Resources/Books/` to folder structure |
| **Placement rules** | "Put nutrition logs under health, not daily notes" | Update placement rule for nutrition content |
| **Naming conventions** | "Use title case for folder names" | Update naming conventions section |
| **Linking rules** | "Always link daily notes to weekly summaries" | Update linking section |
| **Agent behaviors** | "Summarize my day at 9pm" | Add to agent behaviors section (triggers cron separately) |
| **Search relevance** | "Don't search the archive unless I ask" | Update search relevance rules |

#### Design Principles

1. **Confirmation required**: The agent always shows the proposed change and asks for confirmation before modifying the vault guide. This is the user's knowledge system — no silent changes.
2. **Atomic updates**: Each conversational change results in a single, well-defined update to the vault guide. The agent does not rewrite the entire guide.
3. **Separation of concerns**: The vault guide handles *where* and *what format*. Scheduled behaviors (crons, reminders) are a separate system that references the vault guide for placement decisions.
4. **Versioned**: The vault guide is a vault file — it gets versioned like any other file (see [RFC: Vault Backup & Versioning](./2026-03-31-vault-backup-versioning.md)). Users can restore previous guide versions if a change was wrong.

### 2.5 Agent Prompt Requirements for Vault Writing

When agents write markdown to the vault, their system prompt (or tool-specific instructions) MUST include these rules:

1. **Read the vault guide first**: Before writing, the agent reads `_dailywerk/vault-guide.md` to determine where to place the file, which frontmatter fields to include, and which linking conventions to follow. If no guide exists, use the default structure.
2. **Frontmatter from schema**: Use the frontmatter schema defined in the vault guide for the note type being created. Include all fields, even if null — this makes them visible as properties in Obsidian.
3. **Escaped pipes in tables**: When placing a wikilink or embed with an alias inside a table cell, always use `\|` instead of `|`. Example: `[[note\|Display Text]]`, `![[image.png\|300]]`.
4. **One H1 per file**: Use a single `# Title` heading at the top. Subsections use `##` and below.
5. **Wikilinks for cross-references**: Use `[[note-name]]` to link related content, not bare URLs or markdown links.
6. **Confirm before guide changes**: When the user asks to change vault structure, frontmatter schemas, or agent behaviors, the agent MUST show the proposed change and wait for explicit confirmation before calling `update_guide`. Never modify the vault guide silently.
7. **Separate concerns**: When a user request involves both a vault guide change AND a scheduled behavior (cron), handle them as two distinct actions. Update the guide for the "where/what" part, create the cron for the "when" part.

These rules are enforced by documentation and prompt engineering, not by code validation — the vault stores user content as-is. The agent is instructed to follow Obsidian conventions; the system does not reject non-conforming markdown.

### 2.5 What Agents Ignore

- `.obsidian/` — Obsidian app configuration (plugins, themes, hotkeys). Managed by obsidian-headless, excluded from S3 sync and indexing.
- `.trash/` — Obsidian soft-delete folder. Excluded.
- Files starting with `.` — Hidden files. Excluded from indexing.
- **Audio/video files** — Voice messages and media belong in the session/message layer (bridge protocol, channel adapters). If a user places audio/video in their Obsidian vault manually, the files are preserved by sync and S3 backup but are not indexed, not chunked, and cannot be created by agents.

---

## 3. Storage Architecture

### 3.1 S3 as Canonical Store, Disk as Working Copy

```
S3 (Hetzner Object Storage / RustFS)
  workspaces/{workspace_id}/vaults/{slug}/
    diary/2026-03-31.md          ← SSE-C encrypted
    notes/falcon-fiber-model.md  ← SSE-C encrypted
    attachments/receipt.pdf      ← SSE-C encrypted
    .keep                        ← Marker file

Local Disk (working copy)
  /data/workspaces/{workspace_id}/vaults/{slug}/
    diary/2026-03-31.md          ← Plain text (decrypted)
    notes/falcon-fiber-model.md
    attachments/receipt.pdf
```

**Design**: Agents read/write the local checkout. Background jobs sync changes to S3. S3 is the recovery source — local checkouts are ephemeral and reconstructable.

### 3.2 SSE-C Encryption

Each vault gets a unique AES-256 key at creation time:

1. `SecureRandom.random_bytes(32)` generates the key
2. Key is stored in `vaults.encryption_key_enc` using Rails 8 `ActiveRecord::Encryption` (non-deterministic)
3. Every S3 PUT/GET includes SSE-C headers (`sse_customer_algorithm: "AES256"`, `sse_customer_key`, `sse_customer_key_md5`)
4. Hetzner encrypts the object, then discards the key — cross-workspace reads are impossible even if the bucket is compromised

**Key dependency chain**: Rails master key decrypts `encryption_key_enc` decrypts S3 objects. Master key loss = total vault data loss. See [RFC: Vault Backup & Versioning](./2026-03-31-vault-backup-versioning.md) for key recovery procedures.

### 3.3 Vault Size Limits

- **MVP default**: 2 GB per vault (`max_size_bytes`). Conservative to protect the 240 GB NVMe budget on the single Hetzner VPS ([PRD 06](../prd/06-deployment-hetzner.md)).
- **Enforcement**: `VaultS3SyncJob` checks `current_size_bytes` against `max_size_bytes`. If exceeded, vault status transitions to `suspended`, agent writes are blocked, and the workspace owner is notified.
- **OS-level backup**: ext4 project quotas on the vault checkout directory provide defense-in-depth against obsidian-headless writing past the application limit.

---

## 4. Database Schema

All tables use UUIDv7 primary keys. All workspace-scoped tables include `workspace_id` and use the `WorkspaceScoped` concern. RLS policies filter on `app.current_workspace_id`.

### 4.1 Vaults Table

```ruby
class CreateVaults < ActiveRecord::Migration[8.1]
  def change
    create_table :vaults, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string   :name,       null: false
      t.string   :slug,       null: false
      t.string   :vault_type, null: false, default: "native"  # native, obsidian
      t.text     :encryption_key_enc                           # Per-vault AES-256 SSE-C key (Rails encryption)
      t.bigint   :max_size_bytes, default: 2_147_483_648       # 2 GB (MVP conservative)
      t.bigint   :current_size_bytes, default: 0               # Updated by VaultS3SyncJob
      t.integer  :file_count,  default: 0                      # Updated by VaultS3SyncJob
      t.string   :status,      default: "active"               # active, syncing, error, suspended
      t.string   :error_message                                # Last error detail
      t.jsonb    :settings,    default: {}                     # Vault-specific settings
      t.timestamps

      t.index [:workspace_id, :slug], unique: true
      t.index [:workspace_id, :status]
    end

    safety_assured do
      execute "ALTER TABLE vaults ENABLE ROW LEVEL SECURITY;"
      execute "ALTER TABLE vaults FORCE ROW LEVEL SECURITY;"
      execute <<~SQL
        CREATE POLICY workspace_isolation ON vaults
          FOR ALL TO app_user
          USING (workspace_id::text = current_setting('app.current_workspace_id', true))
          WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
      SQL
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON vaults TO app_user;"
    end
  end
end
```

**Note**: `local_path` is computed, not stored: `File.join(Rails.application.config.x.vault_local_base, workspace_id, "vaults", slug)`.

### 4.2 Vault Files Table

```ruby
class CreateVaultFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :vault_files, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :vault,     type: :uuid, null: false, foreign_key: true
      t.references :workspace, type: :uuid, null: false, foreign_key: true  # Denormalized for RLS
      t.string   :path,        null: false              # Relative to vault root: "diary/2026-03-28.md"
      t.string   :content_hash                          # SHA-256 of file content
      t.bigint   :size_bytes
      t.string   :content_type                          # MIME type: text/markdown, image/png, etc.
      t.string   :file_type,   default: "markdown"      # markdown, image, pdf, canvas, audio, video, other
      t.jsonb    :frontmatter, default: {}              # Parsed YAML frontmatter (markdown only)
      t.string   :tags,        array: true, default: [] # Extracted #tags
      t.string   :title                                 # Extracted from H1 or filename
      t.datetime :last_modified                         # Filesystem mtime
      t.datetime :indexed_at                            # Last embedding/chunk update
      t.datetime :synced_at                             # Last S3 sync
      t.timestamps

      t.index [:vault_id, :path], unique: true
      t.index [:workspace_id, :file_type]
      t.index :tags, using: :gin
      t.index :content_hash
    end

    safety_assured do
      execute "ALTER TABLE vault_files ENABLE ROW LEVEL SECURITY;"
      execute "ALTER TABLE vault_files FORCE ROW LEVEL SECURITY;"
      execute <<~SQL
        CREATE POLICY workspace_isolation ON vault_files
          FOR ALL TO app_user
          USING (workspace_id::text = current_setting('app.current_workspace_id', true))
          WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
      SQL
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_files TO app_user;"
    end
  end
end
```

### 4.3 Vault Chunks Table

```ruby
class CreateVaultChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :vault_chunks, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :vault_file, type: :uuid, null: false, foreign_key: true
      t.references :workspace,  type: :uuid, null: false, foreign_key: true  # Denormalized for RLS
      t.string   :file_path,    null: false             # Denormalized for search result display
      t.integer  :chunk_idx,    null: false
      t.text     :content,      null: false
      t.string   :heading_path                          # e.g. "## Setup > ### Prerequisites"
      t.tsvector :tsv                                   # GIN index for keyword search
      t.vector   :embedding, limit: 1536                # HNSW index for semantic search
      t.jsonb    :metadata,     default: {}             # chunk_type, code_language, etc.
      t.timestamps

      t.index :embedding, using: :hnsw, opclass: :vector_cosine_ops
      t.index :tsv, using: :gin
      t.index [:vault_file_id, :chunk_idx], unique: true
      t.index [:workspace_id, :file_path]
    end

    safety_assured do
      execute "ALTER TABLE vault_chunks ENABLE ROW LEVEL SECURITY;"
      execute "ALTER TABLE vault_chunks FORCE ROW LEVEL SECURITY;"
      execute <<~SQL
        CREATE POLICY workspace_isolation ON vault_chunks
          FOR ALL TO app_user
          USING (workspace_id::text = current_setting('app.current_workspace_id', true))
          WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
      SQL
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_chunks TO app_user;"
    end

    # Automatic tsvector generation trigger
    safety_assured do
      execute <<~SQL
        CREATE FUNCTION vault_chunks_tsv_trigger() RETURNS trigger AS $$
        BEGIN
          NEW.tsv := to_tsvector('english', COALESCE(NEW.content, ''));
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;

        CREATE TRIGGER vault_chunks_tsv_update
          BEFORE INSERT OR UPDATE OF content ON vault_chunks
          FOR EACH ROW EXECUTE FUNCTION vault_chunks_tsv_trigger();
      SQL
    end
  end
end
```

### 4.4 Vault Links Table

```ruby
class CreateVaultLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :vault_links, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :source,    type: :uuid, null: false, foreign_key: { to_table: :vault_files }
      t.references :target,    type: :uuid, null: false, foreign_key: { to_table: :vault_files }
      t.references :workspace, type: :uuid, null: false, foreign_key: true  # Denormalized for RLS
      t.string   :link_type,   null: false, default: "reference"  # reference, embed, tag
      t.text     :link_text                             # Original wikilink text: "[[note|alias]]"
      t.text     :context                               # Surrounding text snippet (truncated to 200 chars)
      t.timestamps

      t.index [:source_id, :target_id, :link_type], unique: true
      t.index :target_id                                # Fast backlink lookups
      t.index [:workspace_id, :link_type]
    end

    safety_assured do
      execute "ALTER TABLE vault_links ENABLE ROW LEVEL SECURITY;"
      execute "ALTER TABLE vault_links FORCE ROW LEVEL SECURITY;"
      execute <<~SQL
        CREATE POLICY workspace_isolation ON vault_links
          FOR ALL TO app_user
          USING (workspace_id::text = current_setting('app.current_workspace_id', true))
          WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
      SQL
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_links TO app_user;"
    end
  end
end
```

**Note**: The PRD schema ([01 SS5.6](../prd/01-platform-and-infrastructure.md#56-vault-tables)) omitted `workspace_id` on `vault_links`. It is required here for RLS — without it, PostgreSQL cannot enforce workspace isolation on link queries without a JOIN-based policy.

---

## 5. Models

### 5.1 Vault

```ruby
# app/models/vault.rb
class Vault < ApplicationRecord
  include WorkspaceScoped

  encrypts :encryption_key_enc, deterministic: false

  has_many :vault_files, dependent: :destroy
  has_many :vault_chunks, through: :vault_files
  has_many :vault_links, through: :vault_files, source: :outgoing_links

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :workspace_id },
                   format: { with: /\A[a-z0-9][a-z0-9-]*\z/, message: "must be lowercase alphanumeric with hyphens" }
  validates :vault_type, presence: true, inclusion: { in: %w[native obsidian] }
  validates :status, inclusion: { in: %w[active syncing error suspended] }

  scope :active, -> { where(status: "active") }

  # @return [String] absolute path to local checkout directory
  def local_path
    File.join(
      Rails.application.config.x.vault_local_base,
      workspace_id,
      "vaults",
      slug
    )
  end

  # @return [Boolean] whether the vault has exceeded its size limit
  def over_limit?
    current_size_bytes >= max_size_bytes
  end
end
```

### 5.2 VaultFile

```ruby
# app/models/vault_file.rb
class VaultFile < ApplicationRecord
  include WorkspaceScoped

  belongs_to :vault
  has_many :vault_chunks, dependent: :destroy
  has_many :outgoing_links, class_name: "VaultLink", foreign_key: :source_id, dependent: :destroy
  has_many :incoming_links, class_name: "VaultLink", foreign_key: :target_id, dependent: :destroy
  has_many :versions, class_name: "VaultFileVersion", dependent: :destroy

  validates :path, presence: true, uniqueness: { scope: :vault_id }

  scope :markdown, -> { where(file_type: "markdown") }

  MARKDOWN_EXTENSIONS = %w[.md].freeze
  CANVAS_EXTENSIONS = %w[.canvas].freeze
  IMAGE_EXTENSIONS = %w[.avif .bmp .gif .jpeg .jpg .png .svg .webp].freeze
  AUDIO_EXTENSIONS = %w[.flac .m4a .mp3 .ogg .wav .webm .3gp].freeze
  VIDEO_EXTENSIONS = %w[.mkv .mov .mp4 .ogv .webm].freeze
  PDF_EXTENSIONS = %w[.pdf].freeze

  # File types the agent and API are allowed to create in the vault.
  # Audio/video are message-layer content (voice messages, media from channels),
  # not persistent knowledge. They are preserved if a user places them via
  # Obsidian Sync, but the agent never creates them.
  AGENT_WRITABLE_EXTENSIONS = (MARKDOWN_EXTENSIONS + IMAGE_EXTENSIONS + PDF_EXTENSIONS).freeze

  # @return [String] detected file_type based on extension
  def self.detect_file_type(path)
    ext = File.extname(path).downcase
    case ext
    when *MARKDOWN_EXTENSIONS then "markdown"
    when *CANVAS_EXTENSIONS then "canvas"
    when *IMAGE_EXTENSIONS then "image"
    when *AUDIO_EXTENSIONS then "audio"
    when *VIDEO_EXTENSIONS then "video"
    when *PDF_EXTENSIONS then "pdf"
    else "other"
    end
  end

  # @return [Boolean] whether this file type can be created by agents or the API
  def self.agent_writable?(path)
    AGENT_WRITABLE_EXTENSIONS.include?(File.extname(path).downcase)
  end
end
```

### 5.3 VaultChunk

```ruby
# app/models/vault_chunk.rb
class VaultChunk < ApplicationRecord
  include WorkspaceScoped

  belongs_to :vault_file

  has_neighbors :embedding

  validates :file_path, presence: true
  validates :chunk_idx, presence: true, uniqueness: { scope: :vault_file_id }
  validates :content, presence: true
end
```

### 5.4 VaultLink

```ruby
# app/models/vault_link.rb
class VaultLink < ApplicationRecord
  include WorkspaceScoped

  belongs_to :source, class_name: "VaultFile"
  belongs_to :target, class_name: "VaultFile"

  validates :link_type, presence: true, inclusion: { in: %w[reference embed tag] }
  validates :source_id, uniqueness: { scope: [:target_id, :link_type] }
end
```

### 5.5 Workspace Association

```ruby
# app/models/workspace.rb (add to existing model)
has_many :vaults, dependent: :destroy
```

---

## 6. Service Layer

### 6.1 VaultManager — Vault Lifecycle

```ruby
# app/services/vault_manager.rb
# Creates, configures, and destroys vaults for a workspace.
class VaultManager
  def initialize(workspace:)
    @workspace = workspace
  end

  # @return [Vault] newly created vault with local directory, S3 prefix, and _dailywerk/ guide
  def create(name:, vault_type: "native")
    slug = name.parameterize
    vault = @workspace.vaults.create!(
      name: name,
      slug: slug,
      vault_type: vault_type,
      encryption_key_enc: SecureRandom.random_bytes(32)
    )
    FileUtils.mkdir_p(vault.local_path)
    VaultS3Service.new(vault).ensure_prefix!
    seed_dailywerk_folder(vault)
    vault
  end

  # Called after importing an existing vault (e.g. after initial Obsidian Sync pull).
  # Analyzes structure and generates a vault guide if none exists.
  def analyze_and_guide(vault)
    VaultStructureAnalysisJob.perform_later(vault.id, workspace_id: @workspace.id)
  end

  # Destroys vault, its local checkout, and all S3 objects.
  def destroy(vault)
    FileUtils.rm_rf(vault.local_path) if Dir.exist?(vault.local_path.to_s)
    VaultS3Service.new(vault).delete_prefix!
    vault.destroy!
  end

  private

  # Seeds the _dailywerk/ folder with README and default vault guide.
  def seed_dailywerk_folder(vault)
    file_service = VaultFileService.new(vault: vault)
    file_service.write("_dailywerk/README.md", default_readme)
    file_service.write("_dailywerk/vault-guide.md", default_vault_guide)
  end

  def default_readme
    # Content defined in §2.3 — _dailywerk/README.md template
    <<~MD
      # DailyWerk Configuration

      This folder contains configuration that controls how your DailyWerk AI assistant
      interacts with this vault. The files here affect how the agent places, organizes,
      and navigates your notes.

      ## Files

      - **vault-guide.md** — Structure rules the agent follows. Edit this to change how
        your agent organizes notes. You can edit it here in Obsidian or in the DailyWerk
        web dashboard.
      - **vault-analysis.md** — Auto-generated analysis of your vault's structure. Created
        when you import an existing vault. Read-only reference.

      ## Important

      - Do not delete this folder — DailyWerk will recreate it.
      - Edits to vault-guide.md take effect on the agent's next interaction.
      - This folder is synced by Obsidian Sync and indexed by DailyWerk.
    MD
  end

  def default_vault_guide
    # Content defined in §2.3 — default vault guide template
    Rails.root.join("lib", "templates", "vault_guide_default.md").read
  end
end
```

### 6.2 VaultFileService — File CRUD with Path Safety

```ruby
# app/services/vault_file_service.rb
# Reads, writes, lists, and deletes vault files with path traversal and symlink protection.
class VaultFileService
  class PathTraversalError < SecurityError; end

  def initialize(vault:)
    @vault = vault
    @base = File.realpath(@vault.local_path)
  end

  # @return [String] file content
  def read(path)
    safe = resolve_safe_path(path)
    raise ActiveRecord::RecordNotFound, "File not found: #{path}" unless File.exist?(safe)
    File.read(safe)
  end

  # Writes content to the vault. inotify picks up the change for indexing + S3 sync.
  def write(path, content)
    raise VaultFileService::PathTraversalError, "Vault suspended" if @vault.over_limit?

    safe = resolve_safe_path(path)
    FileUtils.mkdir_p(File.dirname(safe))

    # Atomic write: temp file + rename on same filesystem prevents partial reads
    tmp = "#{safe}.#{SecureRandom.hex(4)}.tmp"
    File.write(tmp, content)
    File.rename(tmp, safe)
  end

  # @return [Array<String>] relative paths matching glob
  def list(glob: "**/*")
    Dir.glob(File.join(@base, glob))
       .reject { |f| File.directory?(f) }
       .reject { |f| ignored_path?(f) }
       .map { |f| f.sub("#{@base}/", "") }
       .sort
  end

  def delete(path)
    safe = resolve_safe_path(path)
    File.delete(safe) if File.exist?(safe)
  end

  private

  # Resolves a relative path to an absolute path within the vault, blocking
  # traversal via ../ and symlinks pointing outside the vault.
  def resolve_safe_path(relative_path)
    full = File.expand_path(relative_path, @base)

    # Walk up to the closest existing ancestor and resolve its real path
    # to catch intermediate directory symlinks
    existing = full
    existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
    real_existing = File.realpath(existing)

    # Reconstruct the full path with the resolved ancestor
    resolved = full.sub(existing, real_existing)

    unless resolved.start_with?("#{@base}/") || resolved == @base
      raise PathTraversalError, "Path traversal detected: #{relative_path}"
    end

    # Final symlink check on the target itself (if it exists)
    if File.symlink?(resolved)
      real_target = File.realpath(resolved)
      unless real_target.start_with?("#{@base}/")
        raise PathTraversalError, "Symlink escape detected: #{relative_path}"
      end
    end

    resolved
  end

  def ignored_path?(path)
    relative = path.sub("#{@base}/", "")
    relative.start_with?(".obsidian/") ||
      relative.start_with?(".trash/") ||
      File.basename(relative).start_with?(".")
  end
end
```

**Security notes** (from Gemini review):
- `File.realpath` on the base directory at initialization ensures intermediate symlinks in the base path itself are resolved.
- Walking up to the closest existing ancestor catches intermediate directory symlinks that `File.expand_path` does not resolve.
- Atomic write via temp file + rename prevents partial reads by concurrent processes.
- `vault.slug` is validated with strict regex in the model (`/\A[a-z0-9][a-z0-9-]*\z/`) to prevent slug injection into filesystem paths.

### 6.3 VaultS3Service — S3 Operations with SSE-C

```ruby
# app/services/vault_s3_service.rb
# Handles S3 operations for a vault with per-vault SSE-C encryption.
class VaultS3Service
  def initialize(vault)
    @vault = vault
    @prefix = "workspaces/#{vault.workspace_id}/vaults/#{vault.slug}/"
    @client = Aws::S3::Client.new(s3_config)
    @bucket = Rails.application.config.x.vault_s3_bucket
  end

  def put_object(relative_path, content)
    safe_key = sanitize_s3_key(relative_path)
    @client.put_object(
      bucket: @bucket,
      key: "#{@prefix}#{safe_key}",
      body: content,
      **sse_c_headers
    )
  end

  def get_object(relative_path)
    safe_key = sanitize_s3_key(relative_path)
    resp = @client.get_object(
      bucket: @bucket,
      key: "#{@prefix}#{safe_key}",
      **sse_c_headers
    )
    resp.body.read
  end

  def delete_object(relative_path)
    safe_key = sanitize_s3_key(relative_path)
    @client.delete_object(bucket: @bucket, key: "#{@prefix}#{safe_key}")
  end

  # Creates a .keep marker to establish the prefix.
  def ensure_prefix!
    put_object(".keep", "")
  end

  # Deletes all objects under the vault prefix.
  def delete_prefix!
    loop do
      resp = @client.list_objects_v2(bucket: @bucket, prefix: @prefix, max_keys: 1000)
      break if resp.contents.empty?

      @client.delete_objects(
        bucket: @bucket,
        delete: { objects: resp.contents.map { |o| { key: o.key } } }
      )

      break unless resp.is_truncated
    end
  end

  # Pulls the full vault from S3 to local checkout.
  def checkout_to_local!
    FileUtils.mkdir_p(@vault.local_path)
    resp = @client.list_objects_v2(bucket: @bucket, prefix: @prefix)
    resp.contents.each do |obj|
      relative = obj.key.delete_prefix(@prefix)
      next if relative.empty? || relative == ".keep"

      local = File.join(@vault.local_path, relative)
      FileUtils.mkdir_p(File.dirname(local))
      File.write(local, get_object(relative))
    end
  end

  # Copies an object to a version key (used by VaultVersioningService).
  def copy_to_version(source_path, version_key)
    content = get_object(source_path)
    @client.put_object(
      bucket: @bucket,
      key: version_key,
      body: content,
      **sse_c_headers
    )
  end

  # Gets an object by exact key (used for version restore).
  def get_by_key(key)
    resp = @client.get_object(bucket: @bucket, key: key, **sse_c_headers)
    resp.body.read
  end

  private

  # Prevents S3 prefix traversal via ../ in the relative path.
  def sanitize_s3_key(relative_path)
    clean = relative_path.gsub(%r{\.\./}, "").gsub(/\A/+/, "")
    raise ArgumentError, "Invalid S3 key: #{relative_path}" if clean.include?("..")
    clean
  end

  def sse_c_headers
    key = @vault.encryption_key_enc # Rails encryption auto-decrypts to raw bytes
    {
      sse_customer_algorithm: "AES256",
      sse_customer_key: key,
      sse_customer_key_md5: Base64.strict_encode64(Digest::MD5.digest(key))
    }
  end

  def s3_config
    {
      region: Rails.application.config.x.vault_s3_region || "us-east-1",
      endpoint: Rails.application.config.x.vault_s3_endpoint,
      access_key_id: Rails.application.credentials.dig(:hetzner_s3, :access_key) ||
                     Rails.application.credentials.dig(:rustfs, :access_key),
      secret_access_key: Rails.application.credentials.dig(:hetzner_s3, :secret_key) ||
                         Rails.application.credentials.dig(:rustfs, :secret_key),
      force_path_style: true
    }
  end
end
```

**Security**: Add `:sse_customer_key` to `config.filter_parameters` to prevent SSE-C keys from leaking into logs.

### 6.4 MarkdownChunker — Heading-Aware Splitting

```ruby
# app/services/markdown_chunker.rb
# Splits markdown into heading-respecting chunks suitable for embedding.
class MarkdownChunker
  MAX_CHUNK_CHARS = 6000     # ~1500 tokens
  MIN_CHUNK_CHARS = 100      # Skip tiny chunks

  # @param content [String] markdown content
  # @param file_path [String] for metadata
  # @return [Array<Hash>] chunks with :content, :heading_path, :chunk_idx, :metadata
  def initialize(content, file_path: nil)
    @content = content
    @file_path = file_path
  end

  def call
    frontmatter, body = extract_frontmatter(@content)
    sections = split_by_headings(body)

    chunks = []
    sections.each do |section|
      if section[:content].length > MAX_CHUNK_CHARS
        split_by_paragraphs(section[:content]).each do |sub|
          chunks << section.merge(content: sub)
        end
      else
        chunks << section
      end
    end

    chunks
      .reject { |c| c[:content].strip.length < MIN_CHUNK_CHARS }
      .each_with_index { |c, i| c[:chunk_idx] = i; c[:metadata] = { frontmatter: frontmatter } }
  end

  private

  def extract_frontmatter(content)
    return [{}, content] unless content.start_with?("---\n")

    parts = content.split("---\n", 3)
    return [{}, content] unless parts.length >= 3

    fm = YAML.safe_load(parts[1], permitted_classes: [Date, Time]) rescue {}
    [fm, parts[2..].join("---\n")]
  end

  def split_by_headings(body)
    sections = []
    current_heading = ""
    current_content = +""

    body.each_line do |line|
      if line.match?(/\A#{1,3}\s/)
        sections << { heading_path: current_heading, content: current_content } if current_content.strip.present?
        current_heading = line.strip
        current_content = +line
      else
        current_content << line
      end
    end

    sections << { heading_path: current_heading, content: current_content } if current_content.strip.present?
    sections
  end

  def split_by_paragraphs(text)
    paragraphs = text.split(/\n{2,}/)
    merged = []
    current = +""

    paragraphs.each do |para|
      if (current.length + para.length) > MAX_CHUNK_CHARS && current.strip.present?
        merged << current
        current = +para
      else
        current << "\n\n" unless current.empty?
        current << para
      end
    end

    merged << current if current.strip.present?
    merged
  end
end
```

### 6.5 VaultLinkExtractor — Wikilink and Embed Parser

```ruby
# app/services/vault_link_extractor.rb
# Parses wikilinks, embeds, and tags from markdown to build the backlink graph.
class VaultLinkExtractor
  # Wikilink regex handles both normal pipes and escaped pipes (\|) for table contexts.
  # [[target]], [[target|alias]], [[target\|alias]] (escaped pipe inside tables)
  WIKILINK_REGEX = /(?<!!)\[\[([^\]|\\]+(?:\\.[^\]|\\]*)*)(?:(?:\||\\|)[^\]]*)?\]\]/
  EMBED_REGEX    = /!\[\[([^\]|\\]+(?:\\.[^\]|\\]*)*)(?:(?:\||\\|)[^\]]*)?\]\]/
  TAG_REGEX      = /(?:^|\s)#([a-zA-Z][a-zA-Z0-9_\/-]+)/

  def initialize(vault:)
    @vault = vault
  end

  # @param content [String] markdown content
  # @return [Array<Hash>] links with :target_path, :link_type, :link_text, :context
  def call(content)
    links = []

    content.each_line do |line|
      # Skip comments
      next if line.strip.start_with?("%%")

      line.scan(WIKILINK_REGEX).each do |match|
        target = match[0]
        links << build_link(target, "reference", "[[#{target}]]", line)
      end

      line.scan(EMBED_REGEX).each do |match|
        target = match[0]
        links << build_link(target, "embed", "![[#{target}]]", line)
      end
    end

    links
  end

  private

  def build_link(raw_target, link_type, link_text, context_line)
    {
      target_path: resolve_target(raw_target),
      link_type: link_type,
      link_text: link_text,
      context: context_line.strip.truncate(200)
    }
  end

  # Resolves a wikilink target to a relative file path.
  # Strips heading references ([[note#heading]] -> note)
  # Adds .md if no extension present.
  def resolve_target(raw)
    base = raw.split("#").first.strip
    base += ".md" unless base.include?(".")
    base
  end
end
```

### 6.6 VaultGuideUpdater — Section-Level Guide Editing

```ruby
# app/services/vault_guide_updater.rb
# Applies targeted section updates to a vault guide without rewriting the entire document.
class VaultGuideUpdater
  # Maps action names to markdown heading patterns in the vault guide.
  SECTION_HEADINGS = {
    "folder_structure"    => "## Folder Structure",
    "placement_rules"     => "## Placement Rules",
    "naming_conventions"  => "## Naming Conventions",
    "frontmatter_schemas" => "## Frontmatter Schemas",
    "linking"             => "## Linking",
    "search_relevance"    => "## Search Relevance",
    "agent_behaviors"     => "## Agent Behaviors"
  }.freeze

  # Replaces a section's content in the vault guide markdown.
  # Finds the section heading and replaces everything up to the next ## heading.
  #
  # @param guide_content [String] current vault guide markdown
  # @param section [String] section key (e.g. "frontmatter_schemas")
  # @param new_section_content [String] new content for that section (without the heading)
  # @return [String] updated guide markdown
  def self.apply_section_update(guide_content, section, new_section_content)
    heading = SECTION_HEADINGS[section]
    raise ArgumentError, "Unknown section: #{section}" unless heading

    # Split on ## headings, preserving them
    parts = guide_content.split(/(?=^## )/m)

    updated = parts.map do |part|
      if part.start_with?(heading)
        "#{heading}\n\n#{new_section_content.strip}\n\n"
      else
        part
      end
    end

    # If the section didn't exist, append it
    unless parts.any? { |p| p.start_with?(heading) }
      updated << "#{heading}\n\n#{new_section_content.strip}\n\n"
    end

    updated.join
  end
end
```

### 6.7 VaultSearchService — Hybrid Search via RRF

```ruby
# app/services/vault_search_service.rb
# Hybrid search combining semantic (pgvector cosine) and keyword (tsvector) via Reciprocal Rank Fusion.
class VaultSearchService
  RRF_K = 60

  def initialize(vault:)
    @vault = vault
  end

  # @param query [String] natural language search query
  # @param limit [Integer] max results to return
  # @return [Array<VaultChunk>] ranked results with vault_file eager-loaded
  def search(query, limit: 5)
    embedding = RubyLLM.embed(query).vectors

    semantic = @vault.vault_chunks
      .nearest_neighbors(:embedding, embedding, distance: "cosine")
      .limit(limit * 3)

    fulltext = @vault.vault_chunks
      .where("vault_chunks.tsv @@ plainto_tsquery('english', ?)", query)
      .limit(limit * 3)

    rrf_scores = Hash.new(0.0)
    semantic.each_with_index { |c, i| rrf_scores[c.id] += 1.0 / (RRF_K + i) }
    fulltext.each_with_index { |c, i| rrf_scores[c.id] += 1.0 / (RRF_K + i) }

    chunk_ids = rrf_scores.sort_by { |_, s| -s }.first(limit).map(&:first)
    VaultChunk.where(id: chunk_ids).includes(:vault_file)
              .index_by(&:id).values_at(*chunk_ids).compact
  end
end
```

---

## 7. Background Jobs

### 7.1 VaultFileChangedJob — Process inotify Events

```ruby
# app/jobs/vault_file_changed_job.rb
# Processes a file change event: updates vault_files metadata, re-chunks, re-embeds, rebuilds links.
class VaultFileChangedJob < ApplicationJob
  include WorkspaceScopedJob
  queue_as :default

  include GoodJob::ActiveJobExtensions::Concurrency
  good_job_control_concurrency_with(
    total_limit: 5,
    key: -> { "vault_file_changed:#{arguments[0]}:#{arguments[1]}" }
  )

  def perform(vault_id, relative_path, event_type, workspace_id:, old_path: nil)
    vault = Vault.find(vault_id)
    return if ignored_path?(relative_path)

    case event_type
    when "create", "modify"
      process_file(vault, relative_path)
    when "move"
      move_file(vault, old_path, relative_path)
    when "delete"
      remove_file(vault, relative_path)
    end
  end

  private

  def process_file(vault, path)
    file_service = VaultFileService.new(vault: vault)
    content = file_service.read(path)
    content_hash = Digest::SHA256.hexdigest(content)

    vault_file = vault.vault_files.find_or_initialize_by(path: path)

    # Skip if content is unchanged
    return if vault_file.persisted? && vault_file.content_hash == content_hash

    vault_file.assign_attributes(
      workspace: vault.workspace,
      content_hash: content_hash,
      size_bytes: content.bytesize,
      content_type: Marcel::MimeType.for(name: path),
      file_type: VaultFile.detect_file_type(path),
      last_modified: File.mtime(File.join(vault.local_path, path)),
      title: extract_title(content, path)
    )

    if vault_file.file_type == "markdown"
      vault_file.frontmatter = extract_frontmatter(content)
      vault_file.tags = extract_tags(content)
    end

    vault_file.save!

    # Re-chunk and re-embed markdown files
    if vault_file.file_type == "markdown"
      rechunk(vault, vault_file, content)
      relink(vault, vault_file, content)
    end

    vault_file.update!(indexed_at: Time.current)
  rescue VaultFileService::PathTraversalError => e
    Rails.logger.warn "[VaultFileChanged] Path safety violation: #{e.message}"
  end

  def rechunk(vault, vault_file, content)
    chunks = MarkdownChunker.new(content, file_path: vault_file.path).call
    vault_file.vault_chunks.delete_all

    chunks.each do |chunk_data|
      chunk = vault_file.vault_chunks.create!(
        workspace: vault.workspace,
        file_path: vault_file.path,
        chunk_idx: chunk_data[:chunk_idx],
        content: chunk_data[:content],
        heading_path: chunk_data[:heading_path],
        metadata: chunk_data[:metadata] || {}
      )
      GenerateEmbeddingJob.perform_later("VaultChunk", chunk.id, user_id: vault.workspace.id)
    end
  end

  def relink(vault, vault_file, content)
    vault_file.outgoing_links.delete_all
    extractor = VaultLinkExtractor.new(vault: vault)
    extractor.call(content).each do |link_data|
      target = vault.vault_files.find_by(path: link_data[:target_path])
      next unless target

      VaultLink.create!(
        source: vault_file,
        target: target,
        workspace: vault.workspace,
        link_type: link_data[:link_type],
        link_text: link_data[:link_text],
        context: link_data[:context]
      )
    end
  end

  # Handles file rename/move: updates path in-place, preserving versions, chunks, and links.
  # Then re-indexes the file at its new path and repairs broken links.
  def move_file(vault, old_path, new_path)
    vault_file = vault.vault_files.find_by(path: old_path)

    if vault_file
      ActiveRecord::Base.transaction do
        # Update the file record's path (preserves ID, versions, links)
        vault_file.update!(
          path: new_path,
          file_type: VaultFile.detect_file_type(new_path),
          title: extract_title(
            File.read(File.join(vault.local_path, new_path)),
            new_path
          )
        )

        # Update denormalized file_path on all chunks
        vault_file.vault_chunks.update_all(file_path: new_path)
      end

      # Re-index content (may have changed during move, and links need updating)
      process_file(vault, new_path)

      # Repair links in other files that referenced the old path
      VaultLinkRepairJob.perform_later(vault.id, old_path, new_path, workspace_id: vault.workspace_id)
    else
      # No existing record for old_path — treat as a new file
      process_file(vault, new_path)
    end
  end

  def remove_file(vault, path)
    vault.vault_files.find_by(path: path)&.destroy!
  end

  def extract_title(content, path)
    # First H1 heading, or filename without extension
    match = content.match(/\A---.*?---\s*\n*#\s+(.+)/m) || content.match(/\A#\s+(.+)/)
    match ? match[1].strip : File.basename(path, ".*").tr("-_", " ").strip
  end

  def extract_frontmatter(content)
    return {} unless content.start_with?("---\n")
    parts = content.split("---\n", 3)
    return {} unless parts.length >= 3
    YAML.safe_load(parts[1], permitted_classes: [Date, Time]) rescue {}
  end

  def extract_tags(content)
    content.scan(/(?:^|\s)#([a-zA-Z][a-zA-Z0-9_\/-]+)/).flatten.uniq
  end

  def ignored_path?(path)
    path.start_with?(".obsidian/") || path.start_with?(".trash/") || File.basename(path).start_with?(".")
  end
end
```

### 7.2 VaultS3SyncJob — Push Changed Files to S3

```ruby
# app/jobs/vault_s3_sync_job.rb
# Syncs changed files from local checkout to S3 (SSE-C encrypted). Runs every 5 minutes via cron.
class VaultS3SyncJob < ApplicationJob
  include WorkspaceScopedJob
  queue_as :default

  include GoodJob::ActiveJobExtensions::Concurrency
  good_job_control_concurrency_with(
    total_limit: 3,
    key: -> { "vault_s3_sync:#{arguments[0]}" }
  )

  def perform(vault_id, workspace_id:)
    vault = Vault.find(vault_id)
    s3 = VaultS3Service.new(vault)
    file_service = VaultFileService.new(vault: vault)

    # Push files modified since last sync
    vault.vault_files.where("last_modified > synced_at OR synced_at IS NULL").find_each do |vf|
      local = File.join(vault.local_path, vf.path)
      next unless File.exist?(local)

      s3.put_object(vf.path, File.read(local))
      vf.update!(synced_at: Time.current)
    end

    # Remove S3 objects for deleted files (files in DB marked for deletion or missing from disk)
    vault.vault_files.find_each do |vf|
      unless File.exist?(File.join(vault.local_path, vf.path))
        s3.delete_object(vf.path)
        vf.destroy!
      end
    end

    # Update vault size metrics
    vault.update!(
      current_size_bytes: vault.vault_files.sum(:size_bytes),
      file_count: vault.vault_files.count
    )

    # Check size limit
    if vault.over_limit?
      vault.update!(status: "suspended", error_message: "Vault size exceeds #{vault.max_size_bytes / 1.gigabyte} GB limit")
    end
  end
end
```

### 7.3 VaultS3SyncAllJob — Cron Entry Point

```ruby
# app/jobs/vault_s3_sync_all_job.rb
# Enqueues S3 sync for all active vaults. GoodJob cron runs this every 5 minutes.
class VaultS3SyncAllJob < ApplicationJob
  queue_as :default

  def perform
    Current.skip_workspace_scoping do
      Vault.active.find_each do |vault|
        VaultS3SyncJob.perform_later(vault.id, workspace_id: vault.workspace_id)
      end
    end
  end
end
```

### 7.4 VaultReindexStaleJob — Catch-Up Indexing

```ruby
# app/jobs/vault_reindex_stale_job.rb
# Re-indexes vault files that are missing embeddings or have stale chunks.
class VaultReindexStaleJob < ApplicationJob
  queue_as :embeddings

  def perform
    Current.skip_workspace_scoping do
      # Files indexed but with chunks missing embeddings
      VaultChunk.where(embedding: nil).find_each do |chunk|
        GenerateEmbeddingJob.perform_later("VaultChunk", chunk.id, user_id: chunk.workspace_id)
      end

      # Files never indexed
      VaultFile.markdown.where(indexed_at: nil).find_each do |vf|
        VaultFileChangedJob.perform_later(
          vf.vault_id, vf.path, "modify",
          workspace_id: vf.workspace_id
        )
      end
    end
  end
end
```

### 7.5 VaultLinkRepairJob — Fix Broken Links After Moves

```ruby
# app/jobs/vault_link_repair_job.rb
# After a file is moved/renamed, updates vault_links that pointed to the old path
# and re-parses all files that contained wikilinks to the old path.
class VaultLinkRepairJob < ApplicationJob
  include WorkspaceScopedJob
  queue_as :default

  def perform(vault_id, old_path, new_path, workspace_id:)
    vault = Vault.find(vault_id)
    old_file = vault.vault_files.find_by(path: old_path)
    new_file = vault.vault_files.find_by(path: new_path)
    return unless new_file

    # Update vault_links whose target pointed to the old file record
    # (if move_file already updated the VaultFile ID, the FK is still valid —
    # but links stored by path in other files' wikilink text are now stale)

    # Find all files that had outgoing links to the moved file and re-parse them
    # to update link_text and context
    if old_file && old_file.id == new_file.id
      # Same record, path was updated in place — re-parse incoming links
      VaultLink.where(target: new_file).find_each do |link|
        VaultFileChangedJob.perform_later(
          vault.id, link.source.path, "modify",
          workspace_id: workspace_id
        )
      end
    end

    # Find files whose content still references the old path via wikilinks
    # and re-parse their links. This catches wikilinks like [[old-name]]
    # that should now point to [[new-name]].
    old_basename = File.basename(old_path, ".*")
    vault.vault_chunks.where("content LIKE ?", "%[[#{old_basename}%").find_each do |chunk|
      VaultFileChangedJob.perform_later(
        vault.id, chunk.file_path, "modify",
        workspace_id: workspace_id
      )
    end
  end
end
```

**Note**: This job re-parses files that reference the old name, which updates the `vault_links` table. It does NOT modify the markdown content of other files (i.e., it does not rewrite `[[old-name]]` to `[[new-name]]` in the source text). Content rewriting is an Obsidian feature (Settings > Files & Links > Automatically update internal links). If the user has this enabled in Obsidian, the sync will bring updated content. If not, the wikilinks will be broken in Obsidian but the `vault_links` table will reflect the correct target via the link extractor's path resolution.

### 7.6 VaultReconciliationJob — Full Disk-vs-DB Consistency Check

```ruby
# app/jobs/vault_reconciliation_job.rb
# Periodic full scan that compares disk state vs DB state and repairs discrepancies.
# Catches any changes missed by inotify (e.g., inotify overflow, watcher restart,
# direct filesystem manipulation, or bulk operations that exceeded the event queue).
class VaultReconciliationJob < ApplicationJob
  queue_as :maintenance

  def perform
    Current.skip_workspace_scoping do
      Vault.active.find_each do |vault|
        reconcile_vault(vault)
      rescue => e
        Rails.logger.error "[VaultReconciliation] Failed for vault #{vault.id}: #{e.message}"
      end
    end
  end

  private

  def reconcile_vault(vault)
    return unless Dir.exist?(vault.local_path)

    file_service = VaultFileService.new(vault: vault)
    disk_files = Set.new(file_service.list(glob: "**/*"))
    db_files = Set.new(vault.vault_files.pluck(:path))

    # Files on disk but not in DB → missed creates
    (disk_files - db_files).each do |path|
      Rails.logger.info "[VaultReconciliation] Detected untracked file: #{path}"
      VaultFileChangedJob.perform_later(vault.id, path, "create", workspace_id: vault.workspace_id)
    end

    # Files in DB but not on disk → missed deletes
    (db_files - disk_files).each do |path|
      Rails.logger.info "[VaultReconciliation] Detected orphaned DB record: #{path}"
      VaultFileChangedJob.perform_later(vault.id, path, "delete", workspace_id: vault.workspace_id)
    end

    # Files on both but with stale content_hash → missed modifications
    vault.vault_files.where(path: (disk_files & db_files).to_a).find_each do |vf|
      local = File.join(vault.local_path, vf.path)
      next unless File.exist?(local)

      disk_hash = Digest::SHA256.hexdigest(File.read(local))
      if disk_hash != vf.content_hash
        Rails.logger.info "[VaultReconciliation] Detected stale content: #{vf.path}"
        VaultFileChangedJob.perform_later(vault.id, vf.path, "modify", workspace_id: vault.workspace_id)
      end
    end
  end
end
```

### 7.7 VaultStructureAnalysisJob — Analyze Imported Vaults

```ruby
# app/jobs/vault_structure_analysis_job.rb
# Analyzes an existing vault's folder structure and generates a vault guide.
# Triggered after importing an existing vault (e.g. after initial Obsidian Sync pull).
class VaultStructureAnalysisJob < ApplicationJob
  include WorkspaceScopedJob
  queue_as :default

  def perform(vault_id, workspace_id:)
    vault = Vault.find(vault_id)
    file_service = VaultFileService.new(vault: vault)

    files = file_service.list(glob: "**/*")
    analysis = analyze_structure(files)

    # Write analysis report
    file_service.write("_dailywerk/vault-analysis.md", format_analysis(analysis))

    # Generate a vault guide if none exists (don't overwrite user's custom guide)
    guide_path = "_dailywerk/vault-guide.md"
    unless File.exist?(File.join(vault.local_path, guide_path))
      guide = generate_guide_from_analysis(vault, analysis)
      file_service.write(guide_path, guide)
    end
  end

  private

  def analyze_structure(files)
    {
      total_files: files.size,
      folders: extract_folder_tree(files),
      naming_patterns: detect_naming_patterns(files),
      date_formats: detect_date_formats(files),
      file_types: files.group_by { |f| VaultFile.detect_file_type(f) }.transform_values(&:count)
    }
  end

  def extract_folder_tree(files)
    files.map { |f| File.dirname(f) }.uniq.sort
  end

  def detect_naming_patterns(files)
    patterns = []
    patterns << "date-prefixed" if files.any? { |f| File.basename(f) =~ /\A\d{4}-\d{2}-\d{2}/ }
    patterns << "kebab-case" if files.count { |f| File.basename(f) =~ /\A[a-z0-9-]+\./ } > files.size / 2
    patterns << "numbered-folders" if files.any? { |f| f =~ %r{\A\d{2}\s*-\s*} }
    patterns
  end

  def detect_date_formats(files)
    files.filter_map { |f| f[/\d{4}-\d{2}-\d{2}/] }.uniq.first(5)
  end

  def format_analysis(analysis)
    <<~MD
      ---
      generated_at: #{Time.current.iso8601}
      ---

      # Vault Structure Analysis

      Auto-generated by DailyWerk. This file is a read-only reference.

      ## Summary

      - **Total files**: #{analysis[:total_files]}
      - **File types**: #{analysis[:file_types].map { |k, v| "#{k} (#{v})" }.join(", ")}
      - **Detected patterns**: #{analysis[:naming_patterns].join(", ").presence || "none"}

      ## Folder Tree

      #{analysis[:folders].map { |f| "- `#{f}/`" }.join("\n")}
    MD
  end

  def generate_guide_from_analysis(vault, analysis)
    # Use LLM to generate a vault guide that matches the existing structure.
    # Falls back to default template if LLM call fails.
    prompt = <<~PROMPT
      Analyze this vault folder structure and generate a vault-guide.md that describes
      where different types of content should be placed. Match the existing conventions.

      Folder tree:
      #{analysis[:folders].join("\n")}

      Naming patterns: #{analysis[:naming_patterns].join(", ")}
      File types: #{analysis[:file_types]}

      Generate a vault guide in the same format as DailyWerk's default template,
      with folder structure, placement rules, naming conventions, and linking rules.
      Adapt to match the existing structure rather than imposing a new one.
    PROMPT

    result = RubyLLM.chat(model: "gpt-4o-mini").with_temperature(0.3).ask(prompt)
    result.content
  rescue => e
    Rails.logger.warn "[VaultStructureAnalysis] LLM guide generation failed: #{e.message}"
    File.read(Rails.root.join("lib", "templates", "vault_guide_default.md"))
  end
end
```

### 7.6 GoodJob Cron Additions

```ruby
# Add to config/initializers/good_job.rb cron hash:
vault_s3_sync: {
  cron: "*/5 * * * *",
  class: "VaultS3SyncAllJob",
  description: "Sync all active vault changes to S3"
},
vault_reindex_stale: {
  cron: "*/30 * * * *",
  class: "VaultReindexStaleJob",
  description: "Re-index vault files missing embeddings or with stale chunks"
},
vault_reconciliation: {
  cron: "0 */6 * * *",
  class: "VaultReconciliationJob",
  description: "Full disk-vs-DB consistency check — catches changes missed by inotify"
}
```

### 7.6 Update GenerateEmbeddingJob

Add `"VaultChunk"` to `EMBEDDABLE_MODELS` in the existing `GenerateEmbeddingJob` ([PRD 04 SS8](../prd/04-billing-and-operations.md#8-goodjob-configuration)).

---

## 8. File Watcher

### 8.1 Standalone VaultWatcher Process

The watcher is a dedicated long-running process, not a GoodJob job. It uses `rb-inotify` to watch all active vault checkouts and enqueues `VaultFileChangedJob` on changes.

```ruby
# lib/vault_watcher.rb
# Standalone process: watches vault checkouts for file changes via inotify.
# Enqueues VaultFileChangedJob for each change. Run via Procfile or systemd.
class VaultWatcher
  DEBOUNCE_SECONDS = 2

  def run
    require "rb-inotify"
    Rails.logger.info "[VaultWatcher] Starting..."

    @notifier = INotify::Notifier.new
    @pending = {}
    @move_sources = {}  # inotify cookie → source path, for pairing moved_from/moved_to
    @mutex = Mutex.new  # Safe here — VaultWatcher runs in its own process, not in Falcon

    setup_watches
    process_loop
  end

  private

  def setup_watches
    Current.skip_workspace_scoping do
      Vault.active.find_each do |vault|
        next unless Dir.exist?(vault.local_path)
        watch_vault(vault)
      end
    end
  end

  def watch_vault(vault)
    Dir.glob(File.join(vault.local_path, "**")).select { |f| File.directory?(f) }.each do |dir|
      @notifier.watch(dir, :modify, :create, :delete, :moved_to, :moved_from) do |event|
        next if event.name.start_with?(".")
        next if event.absolute_name.include?("/.obsidian/")
        next if event.absolute_name.include?("/.trash/")

        relative = event.absolute_name.sub("#{vault.local_path}/", "")

        @mutex.synchronize do
          handle_event(vault, event, relative)
        end
      end
    end
  end

  # inotify provides a "cookie" that pairs moved_from and moved_to events.
  # We use this to detect renames/moves and emit a single "move" event
  # instead of separate delete + create.
  def handle_event(vault, event, relative)
    flags = event.flags

    if flags.include?(:moved_from)
      # Store the source path, keyed by inotify cookie. The matching
      # moved_to event (same cookie) will arrive within milliseconds.
      @move_sources[event.cookie] = {
        vault_id: vault.id,
        workspace_id: vault.workspace_id,
        path: relative,
        at: Time.current
      }
    elsif flags.include?(:moved_to)
      source = @move_sources.delete(event.cookie)
      if source
        # Paired move: source path → destination path
        @pending["move:#{vault.id}:#{relative}"] = {
          vault_id: vault.id,
          workspace_id: vault.workspace_id,
          path: relative,
          old_path: source[:path],
          event_type: "move",
          at: Time.current
        }
      else
        # moved_to without a matching moved_from = file moved in from outside
        @pending["#{vault.id}:#{relative}"] = {
          vault_id: vault.id,
          workspace_id: vault.workspace_id,
          path: relative,
          event_type: "create",
          at: Time.current
        }
      end
    elsif flags.include?(:delete)
      @pending["#{vault.id}:#{relative}"] = {
        vault_id: vault.id,
        workspace_id: vault.workspace_id,
        path: relative,
        event_type: "delete",
        at: Time.current
      }
    else
      @pending["#{vault.id}:#{relative}"] = {
        vault_id: vault.id,
        workspace_id: vault.workspace_id,
        path: relative,
        event_type: "modify",
        at: Time.current
      }
    end
  end

  def process_loop
    Thread.new { flush_loop }  # Safe — own process, not Falcon
    @notifier.run
  end

  def flush_loop
    loop do
      sleep DEBOUNCE_SECONDS
      flush_pending
      expire_orphaned_move_sources
    end
  end

  def flush_pending
    to_process = nil
    @mutex.synchronize do
      cutoff = Time.current - DEBOUNCE_SECONDS
      to_process = @pending.select { |_, v| v[:at] <= cutoff }
      to_process.each_key { |k| @pending.delete(k) }
    end

    to_process&.each_value do |entry|
      VaultFileChangedJob.perform_later(
        entry[:vault_id], entry[:path], entry[:event_type],
        workspace_id: entry[:workspace_id],
        old_path: entry[:old_path]
      )
    end
  end

  # moved_from events without a matching moved_to after the debounce window
  # are treated as deletes (file moved out of the vault entirely).
  def expire_orphaned_move_sources
    cutoff = Time.current - DEBOUNCE_SECONDS * 2
    @mutex.synchronize do
      @move_sources.each do |cookie, source|
        next if source[:at] > cutoff
        @pending["#{source[:vault_id]}:#{source[:path]}"] = source.merge(event_type: "delete")
        @move_sources.delete(cookie)
      end
    end
  end
end
```

**Procfile addition**: `vault_watcher: bundle exec ruby -e "require_relative 'config/environment'; VaultWatcher.new.run"`

**Production**: systemd service unit with `Restart=always`.

**Note on fiber safety**: `VaultWatcher` uses `Thread.new` and `Mutex` — this is safe because it runs as its own OS process, not inside Falcon. The `.claude/rules/01-fiber-safety.md` prohibition on threads applies only to code running within Falcon's fiber reactor.

### 8.2 inotify Limits

Production servers must set `fs.inotify.max_user_watches = 524288` in `/etc/sysctl.conf`. The default (8192) is insufficient for vaults with many directories.

Monitoring: track inotify watch count via `cat /proc/sys/fs/inotify/max_user_watches` and alert in Grafana if usage exceeds 80%.

---

## 9. Agent Integration — VaultTool

```ruby
# app/tools/vault_tool.rb
# Agent tool for reading, writing, searching, and navigating the user's vault.
class VaultTool < RubyLLM::Tool
  description "Read, write, search, and navigate the user's personal knowledge vault. " \
              "Use wikilinks [[like this]] when writing to connect related notes. " \
              "Before writing, use 'guide' to read the vault structure guide. " \
              "Use 'update_guide' to modify vault structure rules after user confirmation."

  param :action, type: :string,
        desc: "guide (read structure rules), update_guide (modify rules after user confirms), " \
              "read, write, list, search, backlinks",
        enum: %w[guide update_guide read write list search backlinks]
  param :path, type: :string, desc: "File path relative to vault root, e.g. '01 - Daily Notes/2026-03/2026-03-31.md'"
  param :content, type: :string, desc: "Markdown content (for write) or updated guide section (for update_guide)"
  param :section, type: :string, desc: "Guide section to update (for update_guide): " \
        "folder_structure, placement_rules, naming_conventions, frontmatter_schemas, " \
        "linking, search_relevance, agent_behaviors"
  param :query, type: :string, desc: "Search query (for search action)"
  param :vault_id, type: :string, desc: "Vault UUID (defaults to primary vault)"

  def initialize(user:, session:)
    @workspace = Current.workspace
    @session = session
  end

  def execute(action:, path: nil, content: nil, query: nil, vault_id: nil)
    vault = resolve_vault(vault_id)
    return { error: "No vault found" } unless vault
    return { error: "Vault is suspended — size limit exceeded" } if vault.status == "suspended" && action == "write"

    case action
    when "guide"        then read_vault_guide(vault)
    when "update_guide" then update_vault_guide(vault, section, content)
    when "read"         then read_file(vault, path)
    when "write"        then write_file(vault, path, content)
    when "list"         then list_files(vault)
    when "search"       then search_vault(vault, query)
    when "backlinks"    then get_backlinks(vault, path)
    end
  rescue VaultFileService::PathTraversalError => e
    { error: "Invalid path: #{e.message}" }
  rescue ActiveRecord::RecordNotFound
    { error: "File not found: #{path}" }
  end

  private

  def resolve_vault(vault_id)
    if vault_id
      @workspace.vaults.active.find_by(id: vault_id)
    else
      @workspace.vaults.active.first
    end
  end

  def read_file(vault, path)
    file_service = VaultFileService.new(vault: vault)
    content = file_service.read(path)
    vault_file = vault.vault_files.find_by!(path: path)
    backlinks = vault_file.incoming_links.includes(:source).map { |l| l.source.path }

    { path: path, content: content, backlinks: backlinks, tags: vault_file.tags,
      frontmatter: vault_file.frontmatter }
  end

  def read_vault_guide(vault)
    file_service = VaultFileService.new(vault: vault)
    guide_path = "_dailywerk/vault-guide.md"
    if File.exist?(File.join(vault.local_path, guide_path))
      { guide: file_service.read(guide_path) }
    else
      { guide: nil, note: "No vault guide found. Use the default structure or ask the user." }
    end
  end

  # Updates a specific section of the vault guide.
  # The agent MUST have shown the proposed change to the user and received confirmation
  # before calling this. The tool does not enforce confirmation — that is the agent's
  # responsibility via its system prompt.
  #
  # @param section [String] which section to update (e.g. "frontmatter_schemas", "agent_behaviors")
  # @param new_content [String] the updated section content (markdown)
  def update_vault_guide(vault, section, new_content)
    return { error: "section and content are required" } if section.blank? || new_content.blank?

    guide_path = "_dailywerk/vault-guide.md"
    file_service = VaultFileService.new(vault: vault)
    full_path = File.join(vault.local_path, guide_path)

    unless File.exist?(full_path)
      return { error: "No vault guide found. Create one first via the dashboard." }
    end

    current = file_service.read(guide_path)
    updated = VaultGuideUpdater.apply_section_update(current, section, new_content)

    # Write via VaultFileService (bypasses the _dailywerk/ block since this is a system operation)
    File.write(full_path, updated)

    { status: "updated", section: section,
      note: "Vault guide updated. Changes take effect on your next interaction." }
  end

  def write_file(vault, path, content)
    unless VaultFile.agent_writable?(path)
      return { error: "Cannot write #{File.extname(path)} files to vault. Only markdown, images, and PDFs are allowed." }
    end

    # Reject writes into _dailywerk/ — managed by the system, not the agent
    if path.start_with?("_dailywerk/")
      return { error: "_dailywerk/ is a system-managed folder. Use the web UI to edit vault settings." }
    end

    file_service = VaultFileService.new(vault: vault)
    file_service.write(path, content)
    { path: path, status: "written", note: "Indexing and S3 sync will happen automatically." }
  end

  def list_files(vault)
    vault.vault_files.order(:path).limit(200)
         .pluck(:path, :file_type, :size_bytes, :last_modified)
         .map { |path, type, size, modified| { path: path, type: type, size: size, modified: modified&.iso8601 } }
  end

  def search_vault(vault, query)
    results = VaultSearchService.new(vault: vault).search(query, limit: 5)
    results.map do |chunk|
      { path: chunk.file_path, heading: chunk.heading_path,
        content: chunk.content.truncate(400), chunk_idx: chunk.chunk_idx }
    end
  end

  def get_backlinks(vault, path)
    file = vault.vault_files.find_by!(path: path)
    file.incoming_links.includes(:source).map do |link|
      { source_path: link.source.path, link_type: link.link_type,
        link_text: link.link_text, context: link.context }
    end
  end
end
```

Update `ToolRegistry` to include `"vault" => VaultTool` when the tool system ships.

---

## 10. Configuration

### 10.1 Rails Configuration

```ruby
# config/environments/development.rb
config.x.vault_s3_bucket = "dailywerk-dev"
config.x.vault_s3_endpoint = "http://localhost:#{ENV.fetch('DAILYWERK_S3_PORT', 9002)}"
config.x.vault_s3_region = "us-east-1"
config.x.vault_local_base = Rails.root.join("tmp/workspaces").to_s

# config/environments/production.rb
config.x.vault_s3_bucket = "dailywerk-vaults"
config.x.vault_s3_endpoint = "https://fsn1.your-objectstorage.com"
config.x.vault_s3_region = "fsn1"
config.x.vault_local_base = "/data/workspaces"
```

```ruby
# config/application.rb (add to filter_parameters)
config.filter_parameters += [:sse_customer_key, :encryption_key_enc]
```

### 10.2 Gemfile Additions

```ruby
gem "rb-inotify", "~> 0.11"   # File system event watching (Linux only)
gem "marcel", "~> 1.0"        # MIME type detection
```

### 10.3 Local Dev vs Production

| Aspect | Local Dev | Production |
|--------|-----------|------------|
| S3 backend | RustFS (localhost:9002) | Hetzner Object Storage |
| Local checkout | `tmp/workspaces/{wid}/vaults/...` | `/data/workspaces/{wid}/vaults/...` |
| File watcher | Optional (can trigger jobs manually) | `vault_watcher` systemd service |
| SSE-C | Depends on RustFS support — test first | Required, per-vault AES-256 |
| inotify limits | Default OK for small dev vaults | `max_user_watches=524288` |

---

## 11. Implementation Phases

### Phase 1: Database + Models

1. Add `rb-inotify` and `marcel` to Gemfile, `bundle install`
2. Create migrations (vaults, vault_files, vault_chunks, vault_links) with RLS
3. Create model files with WorkspaceScoped concern
4. Add `has_many :vaults` to Workspace model
5. `bin/rails db:migrate`
6. **Verify**: `bin/rails console` — create a vault, check local_path computed correctly

### Phase 2: Storage Services

1. Create VaultManager, VaultFileService, VaultS3Service
2. Configure S3 settings for dev (RustFS) and production
3. Add `:sse_customer_key` to `filter_parameters`
4. **Verify**: Create vault → write file → read file → check S3 object exists in RustFS

### Phase 3: Indexing Pipeline

1. Create MarkdownChunker, VaultLinkExtractor, VaultSearchService
2. Create VaultFileChangedJob
3. Update GenerateEmbeddingJob EMBEDDABLE_MODELS to include VaultChunk
4. **Verify**: Process a markdown file → chunks created → embedding generated → search returns results

### Phase 4: Background Sync + Watcher

1. Create VaultS3SyncJob, VaultS3SyncAllJob, VaultReindexStaleJob
2. Add GoodJob cron entries
3. Create VaultWatcher standalone process
4. Add to Procfile
5. **Verify**: Write file to local checkout → watcher fires → job processes → S3 synced

### Phase 5: Agent Integration

1. Create VaultTool
2. Wire into ToolRegistry (when tool system ships)
3. **Verify**: Agent can read, write, search, and navigate backlinks

---

## 12. Known Limitations

| Limitation             | Impact                                       | Future Work                                                         |
| ---------------------- | -------------------------------------------- | ------------------------------------------------------------------- |
| No file versioning     | Overwrites lose previous content             | [RFC: Backup & Versioning](./2026-03-31-vault-backup-versioning.md) |
| No Obsidian Sync       | User must manage files via agent or API      | [RFC: Obsidian Sync](./2026-03-31-obsidian-sync.md)                 |
| No PDF text extraction | PDFs stored but not searchable by content    | Future: PDF-to-text pipeline                                        |
| No canvas file parsing | .canvas files stored but links not extracted | Future: JSON canvas parser                                          |
| No vault dashboard UI  | Files managed via agent tool only            | Future: Frontend file browser RFC                                   |
| 2 GB vault size limit  | Restrictive for heavy users                  | Increase after disk monitoring validates capacity                   |
| Single-language FTS    | tsvector uses 'english' config               | Future: language detection per file                                 |

---

## 13. Verification Checklist

1. `bin/rails db:migrate` succeeds, all 4 tables created with RLS policies
2. `Vault.create!` generates encrypted SSE-C key, computes local_path
3. `VaultFileService.new(vault).write("test.md", "# Hello")` creates file at correct path
4. `VaultFileService.new(vault).read("test.md")` returns content
5. Path traversal attempts (`../../../etc/passwd`, symlink escapes) raise `PathTraversalError`
6. `VaultS3Service.new(vault).put_object` / `get_object` round-trips content with SSE-C
7. `MarkdownChunker.new("# H1\ncontent\n## H2\nmore").call` produces heading-aware chunks
8. `VaultLinkExtractor` parses `[[note]]`, `![[image.png]]`, `#tag` correctly
9. `VaultSearchService.search("query")` returns ranked results via RRF
10. `VaultFileChangedJob.perform_now` processes a file: metadata, chunks, links, embedding enqueued
11. `VaultS3SyncJob.perform_now` pushes changed files to S3
12. Workspace isolation: queries with wrong `app.current_workspace_id` return no rows
13. `bundle exec rails test` passes
14. `bundle exec rubocop` passes
15. `bundle exec brakeman --quiet` shows no critical issues
