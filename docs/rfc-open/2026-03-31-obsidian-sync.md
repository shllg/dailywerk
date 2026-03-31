---
type: rfc
title: Obsidian Sync Integration
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/02-integrations-and-channels
depends_on:
  - rfc/2026-03-30-workspace-isolation
  - rfc/2026-03-31-vault-filesystem
phase: 2
---

# RFC: Obsidian Sync Integration

## Context

DailyWerk supports two vault types: **native** (agent-managed markdown files) and **obsidian** (bidirectionally synced with the user's Obsidian app). This RFC implements the Obsidian Sync integration using `obsidian-headless`, the official headless CLI released by Obsidian in February 2026.

The goal: a user's Obsidian vault on their phone/desktop stays in sync with the DailyWerk server. The agent can read and write to the vault, and changes appear in Obsidian. The user's edits in Obsidian appear on the server for the agent to search and reference.

### What This RFC Covers

- `vault_sync_configs` table for per-vault sync settings and encrypted credentials
- ObsidianSyncManager for process lifecycle (spawn, stop, health check, restart)
- Conflict resolution strategy (remote/user wins)
- Health monitoring via GoodJob cron
- Process credential security
- Non-Obsidian users (native vault, no sync)
- Local dev and production configuration

### What This RFC Does NOT Cover

- Vault filesystem, storage, indexing, search — see [RFC: Vault Filesystem](./2026-03-31-vault-filesystem.md)
- File versioning and backup — see [RFC: Vault Backup & Versioning](./2026-03-31-vault-backup-versioning.md)
- Obsidian plugin development (no custom Obsidian plugin needed)
- Shared vaults (multi-user Obsidian Sync) — future RFC

### Prerequisites

- [RFC: Vault Filesystem](./2026-03-31-vault-filesystem.md) implemented (vaults, vault_files, indexing pipeline, file watcher)
- Node.js 22+ available (Docker container in dev, host or sidecar in production)
- `obsidian-headless` npm package installed globally or in a known path

---

## 1. Obsidian Headless Overview

### 1.1 What It Is

`obsidian-headless` is the official Obsidian CLI (npm package) for server-side vault synchronization. It implements the Obsidian Sync protocol without the desktop GUI.

### 1.2 Commands

| Command | Purpose |
|---------|---------|
| `ob login --email --password [--mfa]` | Authenticate with Obsidian account |
| `ob sync-list-remote` | List available remote vaults |
| `ob sync-setup --vault "Name"` | Connect local directory to a remote vault |
| `ob sync` | One-time sync |
| `ob sync --continuous` | Continuous sync (watches for changes, stays running) |
| `ob sync-status` | Show current sync configuration |
| `ob sync-disconnect` | Disconnect vault from sync |

### 1.3 Sync Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `bidirectional` (default) | Full two-way sync | Standard operation — agent writes go to user, user edits come to server |
| `pull-only` | Download only, ignore local changes | Read-only agent access to user's vault |
| `mirror-remote` | Download only, revert local changes | Strict mirror — agent writes are discarded |

### 1.4 Conflict Resolution (Built-in)

`obsidian-headless` uses Obsidian Sync's conflict resolution:

- **Markdown files**: Three-way merge via Google's diff-match-patch algorithm. Automatic for non-overlapping edits.
- **Non-markdown files** (images, PDFs): Last-modified-wins.
- **Settings/JSON files**: JSON key merge (local on top of remote).
- **Unresolvable conflicts**: Creates `file.sync-conflict-YYYYMMDD-HHMMSS.md` alongside the original.

### 1.5 Requirements

- Node.js 22+
- User's Obsidian Sync subscription (~$4/month, user pays)
- Each instance requires its own device slot in Obsidian Sync (free accounts: 1 device, paid: 5+)

---

## 2. Database Schema

### 2.1 Vault Sync Configs Table

```ruby
class CreateVaultSyncConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :vault_sync_configs, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :vault,     type: :uuid, null: false, foreign_key: true
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string   :sync_type,   null: false, default: "obsidian"  # obsidian, none
      t.string   :sync_mode,   null: false, default: "bidirectional" # bidirectional, pull_only, mirror_remote
      t.text     :obsidian_email_enc                              # Encrypted Obsidian account email
      t.text     :obsidian_password_enc                           # Encrypted Obsidian account password
      t.text     :obsidian_encryption_password_enc                # Encrypted Obsidian E2EE password (optional)
      t.string   :obsidian_vault_name                             # Obsidian remote vault name
      t.string   :device_name, default: "dailywerk-server"       # Device name shown in Obsidian Sync history
      t.string   :process_status, default: "stopped"              # stopped, starting, running, error, crashed
      t.integer  :process_pid                                     # OS PID of obsidian-headless
      t.string   :process_host                                    # Server hostname (for multi-server future)
      t.datetime :last_sync_at
      t.datetime :last_health_check_at
      t.integer  :consecutive_failures, default: 0
      t.string   :error_message
      t.jsonb    :settings, default: {}                           # Additional obsidian-headless flags
      t.timestamps

      t.index [:vault_id], unique: true
      t.index [:workspace_id, :process_status]
    end

    safety_assured do
      execute "ALTER TABLE vault_sync_configs ENABLE ROW LEVEL SECURITY;"
      execute "ALTER TABLE vault_sync_configs FORCE ROW LEVEL SECURITY;"
      execute <<~SQL
        CREATE POLICY workspace_isolation ON vault_sync_configs
          FOR ALL TO app_user
          USING (workspace_id::text = current_setting('app.current_workspace_id', true))
          WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
      SQL
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_sync_configs TO app_user;"
    end
  end
end
```

---

## 3. Model

```ruby
# app/models/vault_sync_config.rb
# Per-vault Obsidian Sync configuration and process tracking.
class VaultSyncConfig < ApplicationRecord
  include WorkspaceScoped

  belongs_to :vault

  encrypts :obsidian_email_enc, deterministic: false
  encrypts :obsidian_password_enc, deterministic: false
  encrypts :obsidian_encryption_password_enc, deterministic: false

  validates :sync_type, presence: true, inclusion: { in: %w[obsidian none] }
  validates :sync_mode, presence: true, inclusion: { in: %w[bidirectional pull_only mirror_remote] }
  validates :vault_id, uniqueness: true

  scope :active_syncs, -> { where(sync_type: "obsidian", process_status: %w[running starting]) }

  # @return [Boolean] whether the process should be running
  def should_run?
    sync_type == "obsidian" && obsidian_email_enc.present? && obsidian_password_enc.present?
  end

  # @return [Boolean] whether too many consecutive failures have occurred
  def failed_permanently?
    consecutive_failures >= ObsidianSyncManager::MAX_CONSECUTIVE_FAILURES
  end
end
```

Add to Vault model:

```ruby
# app/models/vault.rb (add)
has_one :sync_config, class_name: "VaultSyncConfig", dependent: :destroy
```

---

## 4. Sync Architecture

### 4.1 Data Flow

```
User's Obsidian App (phone/desktop)
  | (Obsidian Sync protocol — E2EE optional)
  v
Obsidian Cloud (Obsidian's servers)
  | (obsidian-headless sync --continuous)
  v
DailyWerk Server: /data/workspaces/{workspace_id}/vaults/{slug}/
  |
  |-- inotify (VaultWatcher from RFC: Vault Filesystem)
  |     '-- VaultFileChangedJob: metadata, rechunk, re-embed, relink
  |
  |-- Agent writes (VaultTool)
  |     '-- inotify triggers same pipeline
  |     '-- obsidian-headless picks up local changes -> Obsidian Cloud -> user's app
  |
  '-- VaultS3SyncJob (every 5min): local -> S3 (SSE-C encrypted canonical store)
```

### 4.2 Startup Sequence for Obsidian Vaults

When a user enables Obsidian Sync for a vault:

1. User provides Obsidian email, password, and optionally the E2EE password
2. Credentials encrypted and stored in `vault_sync_configs`
3. `ObsidianSyncManager.setup!` runs:
   a. `ob login` to authenticate
   b. `ob sync-list-remote` to verify the vault exists
   c. `ob sync-setup --vault "VaultName"` to connect the local directory
   d. `ob sync` (one-time) for initial pull
4. Wait for initial sync to complete
5. `VaultStructureAnalysisJob` analyzes the existing vault structure and generates `_dailywerk/vault-guide.md` if none exists (see [RFC: Vault Filesystem §2.3](./2026-03-31-vault-filesystem.md))
6. `VaultFullReindexJob` processes all files (bulk indexing)
7. `ob sync --continuous` starts as a long-running process
8. VaultWatcher (from RFC: Vault Filesystem) handles ongoing change detection

### 4.3 Non-Obsidian Users

Users with `vault_type: "native"` get the identical vault infrastructure (RFC: Vault Filesystem) without `obsidian-headless`:

- Files managed via VaultTool (agent writes) and future dashboard file browser
- S3 sync still runs (canonical store)
- Indexing pipeline identical
- User can later connect Obsidian by adding sync credentials (vault_type changes to "obsidian")

---

## 5. Service Layer

### 5.1 ObsidianSyncManager — Process Lifecycle

```ruby
# app/services/obsidian_sync_manager.rb
# Manages obsidian-headless processes for Obsidian-type vaults.
class ObsidianSyncManager
  MAX_CONSECUTIVE_FAILURES = 5
  RESTART_BACKOFF_SECONDS = [5, 10, 30, 60, 300].freeze

  def initialize(sync_config:)
    @config = sync_config
    @vault = sync_config.vault
  end

  # Initial setup: login, connect vault, first sync.
  # @raise [ObsidianSyncError] if setup fails
  def setup!
    @config.update!(process_status: "starting", error_message: nil)

    run_cli("login", "--email", @config.obsidian_email_enc, "--password", @config.obsidian_password_enc)

    # List remote vaults to verify the vault name
    output = run_cli("sync-list-remote")
    unless output.include?(@config.obsidian_vault_name)
      raise ObsidianSyncError, "Vault '#{@config.obsidian_vault_name}' not found in Obsidian Sync"
    end

    # Connect local directory to remote vault
    run_cli("sync-setup", "--vault", @config.obsidian_vault_name)

    # Initial one-time sync
    run_cli("sync")

    @config.update!(last_sync_at: Time.current)
  rescue => e
    @config.update!(process_status: "error", error_message: e.message)
    raise
  end

  # Start continuous sync as a background process.
  def start!
    return if @config.process_status == "running" && healthy?

    @config.update!(process_status: "starting", error_message: nil)
    pid = spawn_continuous_sync
    @config.update!(
      process_pid: pid,
      process_status: "running",
      process_host: Socket.gethostname,
      consecutive_failures: 0
    )
  end

  # Stop the process gracefully.
  def stop!
    return unless @config.process_pid

    begin
      Process.kill("TERM", @config.process_pid)
      Timeout.timeout(10) { Process.wait(@config.process_pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      # Process already gone
    rescue Timeout::Error
      Process.kill("KILL", @config.process_pid) rescue nil
    end

    @config.update!(process_status: "stopped", process_pid: nil)
  end

  # @return [Boolean] whether the process is alive
  def healthy?
    return false unless @config.process_pid
    Process.kill(0, @config.process_pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Restart with exponential backoff.
  def restart!
    stop!
    backoff = RESTART_BACKOFF_SECONDS[[@config.consecutive_failures, RESTART_BACKOFF_SECONDS.length - 1].min]
    sleep(backoff) # Safe in GoodJob worker context, not in Falcon
    start!
  rescue => e
    @config.update!(
      process_status: "error",
      error_message: e.message,
      consecutive_failures: @config.consecutive_failures + 1
    )
  end

  private

  # Spawns `ob sync --continuous` as a background process.
  # Credentials passed via environment variables (not CLI args) to prevent
  # exposure in /proc/PID/cmdline.
  def spawn_continuous_sync
    cmd = [
      obsidian_headless_bin,
      "sync", "--continuous",
      "--vault-path", @vault.local_path,
      "--mode", @config.sync_mode,
      "--device-name", @config.device_name
    ]

    env = {
      "NODE_ENV" => "production",
      "HOME" => @vault.local_path,
      "OBSIDIAN_EMAIL" => @config.obsidian_email_enc,
      "OBSIDIAN_PASSWORD" => @config.obsidian_password_enc
    }

    if @config.obsidian_encryption_password_enc.present?
      env["OBSIDIAN_ENCRYPTION_PASSWORD"] = @config.obsidian_encryption_password_enc
    end

    log_dir = Rails.root.join("log", "obsidian")
    FileUtils.mkdir_p(log_dir)

    pid = Process.spawn(
      env,
      *cmd,
      chdir: @vault.local_path,
      out: log_dir.join("#{@vault.id}_stdout.log").to_s,
      err: log_dir.join("#{@vault.id}_stderr.log").to_s,
      pgroup: true, # New process group for clean shutdown
      unsetenv_others: true # Prevent leaking host env to child
    )

    Process.detach(pid)
    pid
  end

  # Runs a one-shot obsidian-headless CLI command synchronously.
  def run_cli(*args)
    env = {
      "HOME" => @vault.local_path,
      "OBSIDIAN_EMAIL" => @config.obsidian_email_enc,
      "OBSIDIAN_PASSWORD" => @config.obsidian_password_enc
    }

    cmd = [obsidian_headless_bin, *args]
    stdout, stderr, status = Open3.capture3(env, *cmd, chdir: @vault.local_path)

    unless status.success?
      raise ObsidianSyncError, "obsidian-headless #{args.first} failed: #{stderr.truncate(500)}"
    end

    stdout
  end

  def obsidian_headless_bin
    Rails.application.config.x.obsidian_headless_bin || "ob"
  end

  class ObsidianSyncError < StandardError; end
end
```

**Security decisions** (from Gemini review):

1. **Credentials via env vars, not CLI args**: CLI args are visible in `ps aux` and `/proc/PID/cmdline` to all local users. Environment variables passed via `Process.spawn` are only readable by root and the process owner via `/proc/PID/environ`.

2. **`unsetenv_others: true`**: Prevents the child process from inheriting the Rails process's environment (which may contain database URLs, API keys, etc.).

3. **Process group isolation** (`pgroup: true`): Allows clean shutdown of the entire process tree via `Process.kill("TERM", -pid)`.

### 5.2 VaultConflictResolver — User Wins Strategy

```ruby
# app/services/vault_conflict_resolver.rb
# Handles conflicts between agent writes and Obsidian Sync.
# Strategy: remote (user's Obsidian) always wins. Agent version preserved as .conflict file.
class VaultConflictResolver
  # Called when a file modified by the agent is overwritten by Obsidian Sync.
  def resolve(vault:, path:, agent_content:, remote_content:)
    return if normalize(agent_content) == normalize(remote_content)

    # Save agent's version as a conflict file
    conflict_path = conflict_filename(path)
    VaultFileService.new(vault: vault).write(conflict_path, agent_content)

    Rails.logger.info "[VaultConflict] #{path}: remote wins, agent version at #{conflict_path}"
  end

  private

  def conflict_filename(path)
    ext = File.extname(path)
    base = path.chomp(ext)
    timestamp = Time.current.strftime("%Y%m%d-%H%M%S")
    "#{base}.agent-conflict-#{timestamp}#{ext}"
  end

  def normalize(content)
    content.to_s.strip.gsub(/\r\n/, "\n")
  end
end
```

**Design rationale**: The user's Obsidian is their primary note-taking interface. Agent writes are secondary — the agent can regenerate content, but user edits are irreplaceable. When both modify the same file:

1. Obsidian Sync's built-in three-way merge handles non-overlapping edits automatically.
2. For overlapping edits, `obsidian-headless` creates a `.sync-conflict` file (Obsidian's native behavior).
3. For agent writes overwritten by sync, the agent version is preserved as `.agent-conflict-TIMESTAMP` for later review.

---

## 6. Background Jobs

### 6.1 ObsidianSyncHealthCheckJob — Process Monitoring

```ruby
# app/jobs/obsidian_sync_health_check_job.rb
# Checks health of all running obsidian-headless processes. Restarts crashed ones.
# GoodJob cron: every minute.
class ObsidianSyncHealthCheckJob < ApplicationJob
  queue_as :maintenance

  def perform
    Current.skip_workspace_scoping do
      VaultSyncConfig.where(process_status: %w[running starting]).find_each do |config|
        manager = ObsidianSyncManager.new(sync_config: config)

        if manager.healthy?
          config.update!(last_health_check_at: Time.current)
        else
          handle_unhealthy(config, manager)
        end
      end
    end
  end

  private

  def handle_unhealthy(config, manager)
    Rails.logger.warn "[ObsidianSync] Process #{config.process_pid} for vault #{config.vault_id} is not healthy"

    config.update!(
      process_status: "crashed",
      consecutive_failures: config.consecutive_failures + 1
    )

    if config.failed_permanently?
      config.update!(
        process_status: "error",
        error_message: "Exceeded #{ObsidianSyncManager::MAX_CONSECUTIVE_FAILURES} consecutive failures. Manual intervention required."
      )
      # Future: notify workspace owner via email/notification
    else
      manager.restart!
    end
  end
end
```

### 6.2 VaultFullReindexJob — Bulk Indexing After Initial Sync

```ruby
# app/jobs/vault_full_reindex_job.rb
# Indexes all files in a vault. Used after initial Obsidian Sync pull.
class VaultFullReindexJob < ApplicationJob
  include WorkspaceScopedJob
  queue_as :default

  def perform(vault_id, workspace_id:)
    vault = Vault.find(vault_id)
    file_service = VaultFileService.new(vault: vault)

    file_service.list(glob: "**/*").each do |path|
      VaultFileChangedJob.perform_later(vault.id, path, "create", workspace_id: workspace_id)
    end
  end
end
```

### 6.3 GoodJob Cron Addition

```ruby
# Add to config/initializers/good_job.rb cron hash:
obsidian_sync_health: {
  cron: "* * * * *",
  class: "ObsidianSyncHealthCheckJob",
  description: "Check health of obsidian-headless processes, restart crashed ones"
}
```

---

## 7. Process Management

### 7.1 MVP (Single Server)

`ObsidianSyncManager` spawns processes directly via `Process.spawn`. The health check job monitors them every minute and restarts on failure with exponential backoff.

**Resource budget** (Hetzner CPX41, 16 GB RAM):
- Each `obsidian-headless` process: ~50-150 MB
- MVP budget: 1.5 GB total for sync processes
- At 150 MB per process: ~10 concurrent sync processes
- For 10 test users with 1 vault each: exactly at budget

**Idle management**: For workspaces inactive >24 hours, stop the `obsidian-headless` process. Restart on next agent or user interaction. The local checkout remains on disk (LRU eviction handles disk pressure). On restart, `obsidian-headless` catches up from Obsidian Cloud.

### 7.2 Production Hardening (Post-MVP)

Run `obsidian-headless` in per-workspace Docker containers with:

- Read-write access only to that workspace's vault directory (bind mount)
- Network access limited to Obsidian Cloud endpoints (via `--network` rules)
- CPU limit: 0.5 cores
- Memory limit: 150 MB (`--memory=150m`)
- No access to other workspace data, host filesystem, or Rails secrets

This prevents a compromised `obsidian-headless` process from accessing other workspaces.

---

## 8. Credential Management

### 8.1 Storage

Obsidian Sync credentials (email, password, optional E2EE password) are stored in `vault_sync_configs` using Rails 8 `ActiveRecord::Encryption` in non-deterministic mode:

```ruby
encrypts :obsidian_email_enc, deterministic: false
encrypts :obsidian_password_enc, deterministic: false
encrypts :obsidian_encryption_password_enc, deterministic: false
```

### 8.2 Credential Security Chain

```
User provides credentials via dashboard/API
  -> Rails encrypts with ActiveRecord::Encryption (Rails master key)
  -> Stored in PostgreSQL (encrypted at rest)
  -> Decrypted only when spawning obsidian-headless
  -> Passed to child process via environment variables
  -> Environment cleared from parent after spawn
```

### 8.3 Filter Parameters

```ruby
# config/application.rb (add to existing filter_parameters)
config.filter_parameters += [
  :obsidian_email_enc, :obsidian_password_enc, :obsidian_encryption_password_enc
]
```

---

## 9. User-Facing Obsidian Sync Requirement

Obsidian Sync is the user's subscription (~$4/month). DailyWerk does not pay for or manage it. This must be clearly documented in the user onboarding flow:

1. User must have an active Obsidian Sync subscription
2. DailyWerk registers as a device in the user's Obsidian Sync — this uses one of their device slots
3. **Registering a number with obsidian-headless does NOT deregister the user's phone** (unlike Signal) — Obsidian Sync supports multiple devices
4. The user provides their Obsidian email and password to DailyWerk (stored encrypted)
5. If the user uses Obsidian's end-to-end encryption, they must also provide the E2EE password

---

## 10. Configuration

### 10.1 Rails Configuration

```ruby
# config/environments/development.rb
config.x.obsidian_headless_bin = ENV.fetch("OBSIDIAN_HEADLESS_BIN", "ob")

# config/environments/production.rb
config.x.obsidian_headless_bin = "/usr/local/bin/ob"
```

### 10.2 Node.js 22 Setup

**Development**: Install via `nvm` or system package. `obsidian-headless` installed globally: `npm install -g obsidian-headless`.

**Production**: Node.js 22 installed on the host (not in the Rails container). `obsidian-headless` installed globally. The path is configured via `config.x.obsidian_headless_bin`.

**Future (container isolation)**: Node.js 22 + obsidian-headless baked into a dedicated Docker image. Spawned per workspace with restricted mounts.

### 10.3 Local Dev vs Production

| Aspect | Local Dev | Production |
|--------|-----------|------------|
| obsidian-headless | Optional — can develop with native vaults only | Required for obsidian-type vaults |
| Node.js | System install via nvm | Host install |
| Process management | Manual start/stop | ObsidianSyncManager + health check cron |
| Process isolation | None (dev machine) | Post-MVP: Docker container per workspace |
| Credentials | Dev Obsidian account in Rails credentials | Per-user encrypted in DB |
| Device slots | Uses 1 of user's Obsidian Sync device slots | Same |

---

## 11. Implementation Phases

### Phase 1: Schema + Model

1. Create `vault_sync_configs` migration with RLS
2. Create `VaultSyncConfig` model with encrypted fields
3. Add `has_one :sync_config` to Vault model
4. `bin/rails db:migrate`
5. **Verify**: Create a VaultSyncConfig, credentials are encrypted in DB

### Phase 2: Process Management

1. Create ObsidianSyncManager (setup!, start!, stop!, healthy?, restart!)
2. Install Node.js 22 + obsidian-headless in dev
3. Test login and sync-list-remote with a real Obsidian account
4. **Verify**: `ObsidianSyncManager.new(sync_config:).start!` spawns a process, `healthy?` returns true

### Phase 3: Health Monitoring

1. Create ObsidianSyncHealthCheckJob
2. Add GoodJob cron entry
3. **Verify**: Kill the obsidian-headless process → health check detects → restart succeeds

### Phase 4: Conflict Resolution

1. Create VaultConflictResolver
2. Integrate with VaultFileChangedJob (detect agent-write-then-overwrite pattern)
3. **Verify**: Agent writes file → user edits same file in Obsidian → sync overwrites → conflict file created

### Phase 5: Full Integration Test

1. Create an obsidian-type vault via VaultManager
2. Configure sync credentials
3. Run setup! (login, connect, initial sync)
4. Run VaultFullReindexJob (bulk indexing)
5. Start continuous sync
6. Write a file via VaultTool → verify it appears in Obsidian
7. Edit a file in Obsidian → verify it's indexed on server
8. **Verify**: End-to-end bidirectional sync with indexing

---

## 12. Known Limitations

| Limitation | Impact | Future Work |
|------------|--------|-------------|
| obsidian-headless is early maturity | API may change; undocumented edge cases | Pin npm version, validate on staging first |
| No container isolation (MVP) | Compromised process could access other vaults | Post-MVP: Docker container per workspace |
| Credentials passed via env vars | Visible to root via /proc/PID/environ | Post-MVP: Unix domain socket or stdin pipe |
| No user notification on sync failures | User doesn't know sync is broken | Future: email/push notification on error status |
| No sync progress indicator | User doesn't see initial sync progress | Future: WebSocket progress updates |
| Max ~10 concurrent sync processes | Memory budget constraint on 16 GB server | Increase server size or implement process pooling |
| No MFA support | Users with MFA on Obsidian cannot use sync | obsidian-headless supports --mfa flag — implement in future |

---

## 13. Verification Checklist

1. `bin/rails db:migrate` succeeds, `vault_sync_configs` table created with RLS
2. `VaultSyncConfig.create!` encrypts credentials in DB
3. `ObsidianSyncManager.new(sync_config:).setup!` authenticates and connects vault
4. `ObsidianSyncManager.start!` spawns process, `healthy?` returns true
5. `ObsidianSyncManager.stop!` terminates process gracefully
6. `ObsidianSyncHealthCheckJob` detects dead process and restarts
7. Consecutive failures > 5 → status transitions to "error", no more restarts
8. Credentials not visible in `ps aux` (passed via env, not CLI args)
9. Non-Obsidian vault (`vault_type: "native"`) works without sync_config
10. Workspace isolation: sync configs with wrong `app.current_workspace_id` return no rows
11. `bundle exec rails test` passes
12. `bundle exec rubocop` passes
13. `bundle exec brakeman --quiet` shows no critical issues
