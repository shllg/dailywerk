# Vault Filesystem Developer Guide

> **Scope:** How the vault data layer works, where files live, and how to debug issues.

## Overview

Vaults are workspace-scoped file repositories that sync to S3 and optionally to Obsidian via `obsidian-headless`. The system consists of:

- **Local filesystem** — Human-readable files in `tmp/workspaces/`
- **S3/RustFS** — Encrypted remote storage with SSE-C per-vault keys
- **PostgreSQL** — Metadata, chunks, and embeddings for search
- **VaultWatcher** — Inotify-based file change detection
- **Obsidian Sync** — Bidirectional sync via `obsidian-headless` CLI

## Local Filesystem Layout

### Development

```
tmp/workspaces/
└── {workspace_uuid}/
    └── vaults/
        └── {vault_slug}/
            ├── _dailywerk/
            │   ├── README.md          # Default welcome file
            │   └── vault-guide.md     # Auto-generated structure guide
            ├── notes/
            │   └── ideas.md
            └── projects/
                └── roadmap.canvas
```

### Production

Same layout, but root is controlled by `VAULT_LOCAL_BASE` env var (defaults to `/data/workspaces`).

## Quick Inspection Commands

```bash
# List all workspace directories
ls -la tmp/workspaces/

# Find a specific vault
cd tmp/workspaces/$(uuid)/vaults/my-vault

# Read a file directly
cat tmp/workspaces/.../vaults/my-vault/notes/ideas.md

# Watch the watcher logs
tail -f log/development.log | grep VaultWatcher

# Check S3 sync status (via Rails console)
bin/rails runner "puts VaultS3Service.new(Vault.first).list_objects.keys"
```

## Rails Console Operations

```ruby
# Create a vault
user, workspace = User.first, Workspace.first
vault = VaultManager.new(workspace: workspace).create(name: "test", vault_type: "native")

# Write a file
VaultFileService.new(vault: vault).write("hello.md", "# Hello\n\nWorld!")

# Read it back
puts VaultFileService.new(vault: vault).read("hello.md")

# Trigger reindex
VaultFileChangedJob.perform_now(vault.id, "hello.md", "create", workspace_id: vault.workspace_id)

# Check sync config
puts vault.sync_config&.process_status

# Force structure analysis
VaultManager.new(workspace: workspace).analyze_and_guide(vault)
```

## Local S3 (RustFS)

Development uses RustFS as an S3-compatible local object store:

```bash
# Start services
docker compose up -d

# Access web UI
open http://localhost:9001  # RustFS console
# Credentials: rustfsadmin / rustfsadmin

# Bucket: dailywerk-dev
# Port: 9002 (S3 API), 9001 (Web UI)

# List vault objects via AWS CLI
aws --endpoint-url=http://localhost:9002 s3 ls s3://dailywerk-dev/workspaces/{uuid}/vaults/{slug}/
```

## VaultWatcher (File Change Detection)

The watcher runs via the Procfile in `bin/dev`:

```
vault_watcher: ruby lib/vault_watcher.rb
```

It:
1. Scans all active vaults every 30 seconds
2. Uses `rb-inotify` to watch for file changes
3. Enqueues `VaultFileChangedJob` for each detected change
4. Handles create, modify, delete, and move events

### Monitoring Watcher Health

```bash
# Check if watcher is running
ps aux | grep vault_watcher

# Watch the log stream
tail -f log/development.log | grep -E "(VaultWatcher|VaultFileChanged)"

# Force a manual rescan
bin/rails runner "VaultWatcher.new.send(:scan_for_new_vaults)"
```

## Obsidian Sync

### Prerequisites

```bash
# Install obsidian-headless CLI
npm install -g obsidian-headless

# Verify installation
ob --help
```

### Configuration

Via the **Vault UI** (recommended):
1. Create an "obsidian" type vault
2. Go to the Sync tab
3. Enter credentials (email, password, encryption password)
4. Enter vault name (as shown in your Obsidian app)
5. Enter device name (e.g., "DailyWerk Server")
6. Click "Save Configuration"
7. Click "Setup" to perform initial sync

Via **Rails console**:

```ruby
vault = Vault.find_by(slug: "my-vault")
config = vault.create_sync_config!(
  workspace: vault.workspace,
  sync_type: "obsidian",
  sync_mode: "bidirectional",
  obsidian_email: "user@example.com",
  obsidian_password: "secret",
  obsidian_encryption_password: "optional",
  obsidian_vault_name: "My Second Brain",
  device_name: "DailyWerk Server"
)

# Start sync
ObsidianSyncManager.new(config).setup!  # Login, verify, connect, first sync
ObsidianSyncManager.new(config).start!  # Start continuous sync
```

### Process Management

The sync process runs as a detached child process:

```
ob sync --continuous --vault "My Second Brain"
```

**Security measures:**
- Credentials passed via environment variables (not CLI args)
- `unsetenv_others: true` — child doesn't inherit Rails env
- `pgroup: true` — process group for clean shutdown
- Logs to `log/obsidian/{vault_id}_stdout.log` and `_stderr.log`

### Troubleshooting Obsidian Sync

```bash
# Check process status
bin/rails runner "puts VaultSyncConfig.last.process_status"

# View logs
tail -f log/obsidian/*_stderr.log
tail -f log/obsidian/*_stdout.log

# Check health manually
bin/rails runner "
  config = VaultSyncConfig.last
  puts ObsidianSyncManager.new(config).healthy?
"

# Manual CLI test (with credentials in env)
export OBSIDIAN_EMAIL=...
export OBSIDIAN_PASSWORD=...
cd tmp/workspaces/.../vaults/my-vault
ob login
ob vaults
ob sync --vault "My Vault"

# Restart sync
bin/rails runner "
  config = VaultSyncConfig.last
  ObsidianSyncManager.new(config).restart!
"
```

### Health Check Cron

The `ObsidianSyncHealthCheckJob` runs every minute via GoodJob cron:

```ruby
# config/initializers/good_job.rb
obsidian_sync_health: {
  cron: "* * * * *",
  class: "ObsidianSyncHealthCheckJob"
}
```

It:
1. Scans all running sync processes
2. Checks `Process.kill(0, pid)` for liveness
3. Restarts crashed processes with exponential backoff
4. Marks permanently failed after 5 attempts

## Common Issues

### "Permission denied" on vault create

Check `VAULT_LOCAL_BASE` env var. In tests, it should be `tmp/workspaces`. In production, ensure the directory is writable.

### Files not appearing in search

Check if `VaultFileChangedJob` ran successfully:

```ruby
file = VaultFile.find_by(path: "notes/hello.md")
puts file.indexed_at  # Should be recent
puts file.vault_chunks.count  # Should be > 0 for markdown
```

### S3 sync not working

```bash
# Check S3 connectivity
bin/rails runner "puts VaultS3Service.new(Vault.first).bucket.exists?"

# Force a sync
bin/rails runner "VaultS3SyncJob.perform_now(Vault.first.id, workspace_id: Vault.first.workspace_id)"
```

### Obsidian sync stuck in "starting"

1. Check logs: `tail -f log/obsidian/*_stderr.log`
2. Verify CLI available: `which ob`
3. Test credentials manually with `ob login`
4. Check if vault name matches exactly (case-sensitive)

## Architecture Reference

```
┌─────────────────────────────────────────────────────────────────┐
│                         User / Agent                             │
└────────────────┬────────────────────────────────┬─────────────────┘
                 │                                │
                 ▼                                ▼
        ┌─────────────┐                  ┌─────────────┐
        │  Vault UI   │                  │  Chat Tool  │
        │  (React)    │                  │  (Runtime)  │
        └──────┬──────┘                  └──────┬──────┘
               │                               │
               ▼                               ▼
        ┌─────────────┐                  ┌─────────────┐
        │   Vaults    │                  │  VaultTool  │
        │ Controller  │                  │   (Agent)   │
        └──────┬──────┘                  └──────┬──────┘
               │                               │
               └───────────────┬───────────────┘
                               │
                    ┌──────────┴──────────┐
                    │                     │
                    ▼                     ▼
           ┌─────────────┐        ┌─────────────┐
           │ VaultManager│        │VaultFileSvc │
           │ (create/    │        │(read/write) │
           │  destroy)   │        └──────┬──────┘
           └──────┬──────┘               │
                  │                      │
        ┌─────────┼──────────┐           │
        │         │          │           │
        ▼         ▼          ▼           ▼
   ┌────────┐ ┌──────┐ ┌────────┐ ┌──────────┐
   │  S3    │ │  DB  │ │ Files  │ │ Vault    │
   │(RustFS)│ │(PG)  │ │(Local) │ │ Watcher  │
   └────────┘ └──────┘ └────────┘ └──────────┘
                                          │
                                          ▼
                                   ┌────────────┐
                                   │ inotify    │
                                   │ (kernel)   │
                                   └────────────┘
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_LOCAL_BASE` | `tmp/workspaces` (dev) | Local vault root path |
| `OBSIDIAN_HEADLESS_BIN` | `ob` | Path to obsidian-headless CLI |
| `AWS_ENDPOINT` | `http://localhost:9002` | S3/RustFS endpoint |
| `S3_BUCKET` | `dailywerk-dev` | S3 bucket name |

## See Also

- `docs/prd/02-integrations-and-channels.md` — Vault sync architecture
- `docs/prd/03-agentic-system.md` — Agent tools (VaultTool)
- `docs/rfc-done/2026-03-31-vault-filesystem.md` — Original vault RFC
- `lib/vault_watcher.rb` — File watcher implementation
- `app/services/obsidian_sync_manager.rb` — Sync process management
