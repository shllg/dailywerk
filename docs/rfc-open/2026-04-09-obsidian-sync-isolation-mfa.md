# RFC: Obsidian Sync — Multi-User Isolation, CLI Fixes, and MFA Support

**Date:** 2026-04-09
**Status:** Open
**Author:** AI Planning Team (Researcher + Architect + Validator + Gemini cross-verification)

---

## Problem Statement

The `ObsidianSyncManager` service is broken in multiple ways:

1. **Wrong CLI commands** — The service uses outdated/incorrect `ob` CLI syntax that doesn't match the actual obsidian-headless CLI interface
2. **No multi-user isolation** — All sync processes share a single CLI config directory, causing auth token collisions when multiple users sync simultaneously
3. **No MFA support** — Users with 2FA-enabled Obsidian accounts cannot set up sync

These issues mean the current implementation is **likely non-functional** for any user.

---

## Current State (What's Broken)

### File Map

| File | Lines | Role |
|------|-------|------|
| `app/services/obsidian_sync_manager.rb` | 331 | Process lifecycle: setup!, start!, stop!, healthy?, restart! |
| `app/models/vault_sync_config.rb` | 63 | Encrypted credential storage, status tracking |
| `app/controllers/api/v1/vault_sync_configs_controller.rb` | 144 | CRUD + setup/start/stop actions (all async via jobs) |
| `app/jobs/obsidian_sync_setup_job.rb` | 40 | Runs setup! -> start! -> analyze -> reindex |
| `app/jobs/obsidian_sync_start_job.rb` | 27 | Runs start! |
| `app/jobs/obsidian_sync_stop_job.rb` | ~27 | Runs stop! |
| `app/jobs/obsidian_sync_restart_job.rb` | ~30 | Runs restart! with failure tracking |
| `app/jobs/obsidian_sync_health_check_job.rb` | 83 | Cross-workspace cron, every minute |
| `db/migrate/20260409010000_create_vault_sync_configs.rb` | 54 | Schema + RLS |

### CLI Command Errors

| Step | Current Code | Correct Syntax | Bug |
|------|-------------|----------------|-----|
| **login** | `Open3.capture3({OBSIDIAN_EMAIL: ..., OBSIDIAN_PASSWORD: ...}, ["ob", "login"])` | `ob login --email ... --password ... [--mfa ...]` | CLI does NOT read env vars for login; expects flags |
| **verify vault** | `["ob", "vaults"]` | `ob sync-list-remote` | Wrong command name |
| **connect** | `["ob", "connect", "--vault", name, "--device", device]` | `ob sync-setup --vault "Name" --path /local/path --device-name "Device" [--password encryption_pw]` | Wrong command, wrong flags, missing --path |
| **one-shot sync** | `["ob", "sync", "--vault", name]` | `ob sync --path /local/path` | --vault not valid; uses --path |
| **continuous sync** | `["ob", "sync", "--continuous", "--vault", name]` | `ob sync --continuous --path /local/path` | Same --vault issue |

### Environment Isolation Bug

All `Open3.capture3` and `Process.spawn` calls use `unsetenv_others: true`, which strips ALL environment variables. The only vars passed are `OBSIDIAN_EMAIL` and `OBSIDIAN_PASSWORD` — which the CLI doesn't even read. This means:
- No `PATH` — the `ob` Node.js binary can't find `node`
- No `HOME` — npm module resolution fails
- No `XDG_CONFIG_HOME` — CLI can't find/write its auth token

**Consequence:** Login likely fails silently or crashes. The entire sync pipeline after login is dead.

### Multi-User Collision

The `ob` CLI stores its auth token at `$XDG_CONFIG_HOME/obsidian-headless/auth_token` (defaults to `~/.config/obsidian-headless/auth_token`). Without isolation, if User A logs in and then User B logs in, User B's token overwrites User A's. User A's continuous sync process silently uses User B's token — syncing the wrong vault or failing auth.

---

## Architecture Decision: XDG Isolation vs OBSIDIAN_AUTH_TOKEN

### Option A: Per-Config XDG Directory Isolation

Each `VaultSyncConfig` gets its own XDG base directory:
```
{vault_local_base}/{workspace_id}/config/{sync_config_id}/
  ├── config/obsidian-headless/auth_token
  ├── data/
  ├── state/
  └── cache/
```

Every CLI invocation sets `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` to these subdirectories.

**Pros:**
- Complete isolation — auth tokens, sync state, device registration, E2EE keys all separated
- Works with the full CLI lifecycle (login -> setup -> sync)
- No new database columns needed

**Cons:**
- Config dirs are host-local — multi-host deployments need shared filesystem (NFS/EFS) or per-host re-login
- Cleanup needed on VaultSyncConfig destroy
- Disk usage (negligible — auth tokens are < 1KB)

### Option B: OBSIDIAN_AUTH_TOKEN Env Var Only

Login once with a temp XDG dir, extract the auth token, store encrypted in DB, pass `OBSIDIAN_AUTH_TOKEN=<token>` to all subsequent CLI calls.

**Pros:**
- Token lives in DB — works across hosts without shared filesystem
- No config dir management or cleanup

**Cons (FATAL):**
- **`ob sync` needs more than just the auth token.** Gemini confirmed: the CLI stores sync history/merkle trees, device registration, and E2EE encryption keys in the XDG config directory. These are written by `ob sync-setup` and read by `ob sync --continuous`. Without them, `ob sync` would need to do a full rescan on every start and may fail entirely if device registration state is missing.
- This means Option B is **not viable** as a standalone solution — it effectively collapses back into Option A (needing a persistent config dir anyway).

### Decision: Option A (XDG Isolation) + Auth Token in DB for Recovery

**Use Option A** as the primary mechanism. Additionally, consider storing the auth token encrypted in the DB as a recovery mechanism — if the XDG dir is ever lost (container restart, disk failure), the system can re-bootstrap without needing the user's plaintext Obsidian password again. This is a future enhancement, not required for the initial fix.

---

## Critical Bugs to Fix (Beyond CLI Commands)

These were discovered during code review and affect the current implementation regardless of the CLI command changes.

### C1: Destroy Race — Orphaned Processes

**File:** `app/controllers/api/v1/vault_sync_configs_controller.rb:47-53`

```ruby
# Current (broken):
ObsidianSyncStopJob.perform_later(config.id, workspace_id: vault.workspace_id)
config.destroy!  # ← Record gone before job runs
```

The stop job has `discard_on ActiveRecord::RecordNotFound`. When it executes, the record is already deleted, so the job silently discards. The `ob sync --continuous` process is never killed. The PID is lost forever.

**Fix:** Two-phase delete. The API cannot block for up to 35 seconds waiting for process shutdown. Instead:
1. Mark the config for deletion (e.g., `process_status: "deleting"`)
2. Enqueue `ObsidianSyncDestroyJob` which: stops the process (with PID/host passed as primitives), cleans up the XDG config directory, then destroys the record
3. The controller returns 202 Accepted immediately

### C2: No Concurrency Controls on Sync Jobs

**Files:** All `app/jobs/obsidian_sync_*.rb`

None of the 5 sync jobs use `good_job_control_concurrency_with`. A double-click on "Setup" enqueues two setup jobs for the same config — two `ob login` calls race to write the same auth_token file, two `Process.spawn` calls create duplicate continuous sync processes (only one PID stored).

**Fix:** Add `good_job_control_concurrency_with(perform_limit: 1, key: -> { "obsidian_sync_#{arguments.first}" })` to all sync jobs.

### C3: stop! Clears PID Before SIGTERM

**File:** `app/services/obsidian_sync_manager.rb:114`

`stop!` calls `update_status("stopped")` on line 114, which sets `process_pid: nil` in the DB (line 325-326). SIGTERM isn't sent until line 118. If `stop!` crashes between those lines, the process is a permanent orphan — running but invisible to health checks.

**Fix:** Add `"stopping"` to `PROCESS_STATUSES`. Transition to `"stopping"` (preserving PID) before sending SIGTERM. Only clear PID and transition to `"stopped"` after the process has actually exited. Update health check and other status-checking code to handle the new status.

### H1: unsetenv_others Strips Essential Variables

**File:** `app/services/obsidian_sync_manager.rb:76,237`

`unsetenv_others: true` is correct for security (don't leak Rails env), but the replacement env hash must include at minimum:
- `PATH` — to find `node` runtime
- `HOME` — for npm module resolution
- `XDG_CONFIG_HOME` (+ DATA/STATE/CACHE) — for auth token and sync state

### H2: Token Revocation Burns All Retries Without Re-Login

**File:** `app/jobs/obsidian_sync_health_check_job.rb:74-79`

When a token is revoked, `ob sync --continuous` crashes immediately. The health check detects the crash and schedules `ObsidianSyncRestartJob`. But `restart!` only does `stop! + start!` — it does NOT re-login. Each restart spawns a process that immediately crashes on auth failure. After 5 cycles (~7 min), permanent error.

**Fix (future):** Parse stderr for auth errors. If detected, transition to an `"auth_required"` status instead of retrying. Surface this to the user via the UI so they can re-authenticate.

### H3: MFA Re-Auth Impossible in Background

If the token expires AND the user has MFA enabled, re-login requires a one-time TOTP code. The system has no way to obtain this automatically. This is an inherent limitation — the "fix" is good UX: detect auth failures, surface them clearly, and provide a one-click re-auth flow in the UI.

---

## Implementation Plan

### Phase 1: CLI Command Fixes + Unified Runner

**Files:** `app/services/obsidian_sync_manager.rb` only

1. Add `#run_cli(args)` — unified wrapper around `Open3.capture3` with proper env
2. Add `#build_env` — returns `{ PATH, HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, XDG_CACHE_HOME }`
3. Remove `#build_credential_env` (env vars the CLI doesn't read)
4. Fix `#login!` — use `--email`, `--password`, `--mfa` flags
5. Fix `#verify_vault!` — `ob sync-list-remote` instead of `ob vaults`
6. Fix `#connect!` — `ob sync-setup --vault ... --path ... --device-name ... [--password ...]`
7. Fix `#sync!` — `ob sync --path ...`
8. Fix `#start!` — `ob sync --continuous --path ...`, use `build_env` instead of `build_credential_env`

### Phase 2: XDG Config Directory Isolation

**Files:** `obsidian_sync_manager.rb`, `vault_sync_config.rb`

1. Add `#config_base_path` to both service and model (derived from workspace path + config ID)
2. Add `#xdg_env` returning all 4 XDG directory paths scoped to the config
3. Add `#ensure_config_directories!` — creates dirs with 0700 permissions
4. Wire `xdg_env` into `build_env`
5. Add `after_destroy :cleanup_config_directory` to model
6. Call `ensure_config_directories!` at the start of `setup!`

### Phase 3: MFA Passthrough

**Files:** `obsidian_sync_manager.rb`, `obsidian_sync_setup_job.rb`, `vault_sync_configs_controller.rb`

1. Add `mfa_code:` keyword to `setup!` and `login!`
2. Add `mfa_code:` keyword to `ObsidianSyncSetupJob#perform`
3. Extract `mfa_code` from params in controller `#setup` action, pass to job
4. MFA code is never persisted in the model — it flows API -> job -> service -> CLI

### Phase 4: Bug Fixes (C1, C2, C3)

**Files:** Controller, all sync jobs, service, model

1. **C1 (destroy race):** Two-phase delete — mark config as `"deleting"`, enqueue `ObsidianSyncDestroyJob` with PID/host/config_base_path as primitives, return 202. Job stops process, cleans up XDG dir, destroys record. Add `"deleting"` to `PROCESS_STATUSES`.
2. **C2 (concurrency):** Add `good_job_control_concurrency_with(perform_limit: 1, key: -> { "obsidian_sync_#{arguments.first}" })` to all sync jobs (setup, start, stop, restart, and new destroy job).
3. **C3 (PID clearing):** Add `"stopping"` to `PROCESS_STATUSES`. Transition to `"stopping"` (preserving PID) before SIGTERM. Only clear PID after confirmed exit. Update health check to handle `"stopping"` status.
4. **H2 (auth failure detection):** Parse stderr log file for auth-related error patterns after process crash. If auth failure detected, transition to `"auth_required"` status (add to `PROCESS_STATUSES`) instead of retrying. Surface via API/ActionCable so the UI can prompt re-auth.

### Phase 5: Tests

**File:** `test/services/obsidian_sync_manager_test.rb`

1. Test CLI arg construction for all 5 commands (stub `Open3.capture3` / `Process.spawn`)
2. Test XDG env isolation — verify 4 XDG vars contain config ID
3. Test MFA passthrough — verify `--mfa` flag present when code provided
4. Test config dir cleanup on model destroy
5. Test concurrency controls on jobs

### Phase 6: Periodic Sync Mode (Replace --continuous)

**Files:** `obsidian_sync_manager.rb`, `config/initializers/good_job.rb`, new `obsidian_sync_periodic_job.rb`

Replace `ob sync --continuous` (long-running spawned process) with periodic one-shot `ob sync --path ...` runs via GoodJob cron. This eliminates:
- Long-running process management (spawn, detach, health check, PID tracking)
- Zombie/orphan process risks
- Process group signal handling complexity
- The entire `start!`/`stop!`/`healthy?`/`restart!` lifecycle

Replace with:
1. New `ObsidianSyncPeriodicJob` — runs `ob sync --path ...` every 1-5 minutes (configurable per sync config)
2. Register as GoodJob cron or use `good_job_control_concurrency_with` to prevent overlap
3. Process status simplifies to: `stopped`, `syncing`, `error`, `auth_required`, `deleting`
4. No PID tracking, no process_host, no health check job needed

**Note:** This trades real-time sync for simplicity and reliability. Vault changes appear within 1-5 minutes instead of seconds. For the MVP this is acceptable — users are syncing personal knowledge bases, not collaborative real-time documents.

### Phase 7: Future Enhancements (Out of Scope)

- UI re-auth flow with MFA prompt
- Store auth token in DB for recovery after config dir loss
- `filter_parameter_logging` for `mfa_code`
- Multi-host scaling (see `docs/rfc-open/2026-04-09-obsidian-sync-scaling.md`)

---

## Data Flow Diagram

```
User clicks "Setup Sync" (with optional MFA code)
  |
  v
POST /api/v1/vaults/:id/sync_config/setup
  { sync_config: { mfa_code: "123456" } }
  |
  v
VaultSyncConfigsController#setup
  - Extracts mfa_code from params (NOT persisted to model)
  - ObsidianSyncSetupJob.perform_later(config.id, workspace_id:, mfa_code:)
  - Returns 202 Accepted
  |
  v
ObsidianSyncSetupJob#perform (GoodJob external worker)
  - manager = ObsidianSyncManager.new(config)
  - manager.setup!(mfa_code:)
  |
  v
ObsidianSyncManager#setup!(mfa_code:)
  1. ensure_config_directories!
     → Creates {vault_base}/{ws_id}/config/{config_id}/{config,data,state,cache}/
     → Permissions 0700
  2. login!(mfa_code:)
     → ENV: { PATH, HOME, XDG_CONFIG_HOME=isolated_dir, ... }
     → CMD: ob login --email user@example.com --password secret [--mfa 123456]
     → Auth token written to isolated XDG_CONFIG_HOME/obsidian-headless/auth_token
  3. verify_vault!
     → CMD: ob sync-list-remote
     → Verifies vault name exists in account
  4. connect!
     → CMD: ob sync-setup --vault "My Vault" --path /data/.../vaults/my-vault --device-name "DailyWerk"
     → Registers device, configures E2EE, writes sync state to XDG dirs
  5. sync!
     → CMD: ob sync --path /data/.../vaults/my-vault
     → One-shot pull of all vault content
  |
  v
ObsidianSyncPeriodicJob (GoodJob cron, every 1-5 minutes)
  → good_job_control_concurrency_with(perform_limit: 1, key: sync_config_id)
  → manager = ObsidianSyncManager.new(config)
  → manager.sync!  →  ob sync --path /data/.../vaults/my-vault
  → One-shot sync, job exits immediately after
  → On auth failure: transition to "auth_required", notify user
  → On transient error: increment consecutive_failures, retry with backoff
```

---

## XDG Directory Layout

```
{VAULT_LOCAL_BASE}/
└── {workspace_uuid}/
    ├── vaults/
    │   └── {vault_slug}/          # Vault content (markdown files, etc.)
    │       ├── notes/
    │       └── projects/
    └── config/
        └── {sync_config_uuid}/    # Isolated CLI state (NEW)
            ├── config/
            │   └── obsidian-headless/
            │       └── auth_token     # Plaintext auth token (0700 dir)
            ├── data/                  # Sync history, device registration
            ├── state/                 # E2EE keys, vault mapping
            └── cache/                 # Temp download cache
```

Each VaultSyncConfig gets a completely isolated CLI state directory. No cross-contamination between users or vaults.

---

## Security Considerations

| Concern | Assessment | Mitigation |
|---------|-----------|------------|
| `--password` visible in `ps aux` | Medium risk. Login is a short-lived `capture3` call (seconds). Only same-UID processes can read `/proc/PID/cmdline`. | Accept for now. Add TODO for stdin support if CLI adds it. Periodic `ob sync` calls do NOT receive credentials — they use the auth token from the XDG config dir. |
| Auth token plaintext on disk | Low risk. Token file is in a 0700 directory. Same protection as SSH keys. | Strict directory permissions. Cleanup on config destroy. |
| MFA code in GoodJob queue | Low risk. MFA codes are single-use TOTP (30-60s validity). Serialized briefly in job args, consumed immediately. | Consider adding `mfa_code` to `filter_parameter_logging`. |
| Config dir traversal | Low risk. Paths are derived from UUIDs (not user input). No user-controllable path components. | Validate that `config_base_path` is within expected parent directory. |
| Encryption password as CLI arg | Same as login password. `ob sync-setup --password ...` is the E2EE vault password, visible in `ps aux` briefly during setup. | Same mitigation as login. Short-lived `capture3` call only. |

---

## Resolved Decisions

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Synchronous stop on destroy? | **No. Two-phase delete.** | API cannot block 35s. Mark as `"deleting"`, enqueue `ObsidianSyncDestroyJob` with PID/host/path as primitives, return 202. |
| 2 | Add `"stopping"` status? | **Yes.** | Preserves PID during shutdown. Prevents orphans if `stop!` crashes mid-execution. Also add `"deleting"` and `"auth_required"`. |
| 3 | Auth failure detection? | **Parse stderr logs + check auth_token file.** | Must be rock solid. Read the process stderr log file after crash, match known auth error patterns. Cross-reference with auth_token file existence/staleness. Transition to `"auth_required"` status, surface via API. |
| 4 | Shared filesystem? | **Not needed for MVP.** | Single-server deployment. Scaling concerns tracked separately in `docs/rfc-open/2026-04-09-obsidian-sync-scaling.md`. |
| 5 | `--continuous` vs periodic sync? | **Replace with periodic `ob sync`.** | Eliminates entire process management subsystem (spawn, detach, PID tracking, health check, signal handling, orphan recovery). GoodJob cron handles scheduling. 1-5 min sync interval is acceptable for personal knowledge bases. |

### New Process Statuses

After these changes, `PROCESS_STATUSES` becomes:

```ruby
PROCESS_STATUSES = %w[stopped syncing error auth_required deleting stopping].freeze
```

| Status | Meaning | PID present? |
|--------|---------|-------------|
| `stopped` | No sync activity | No |
| `syncing` | Periodic sync running (Phase 6) or continuous process running (Phase 1-5) | Yes (continuous) / No (periodic) |
| `stopping` | SIGTERM sent, waiting for exit | Yes |
| `error` | Permanent failure (max retries exceeded) | No |
| `auth_required` | Auth token invalid, user must re-authenticate | No |
| `deleting` | Marked for deletion, cleanup in progress | Maybe |

---

## References

- `app/services/obsidian_sync_manager.rb` — Current (broken) implementation
- `app/models/vault_sync_config.rb` — Model with encrypted credentials
- `docs/dev/vault-filesystem.md` — Vault filesystem developer guide
- `docs/rfc-done/2026-03-31-obsidian-sync.md` — Original sync RFC
- `docs/rfc-open/2026-04-09-obsidian-sync-scaling.md` — Scaling architecture research
- obsidian-headless CLI — `ob --help`, `ob login --help`
