# RFC: Scaling Obsidian Sync Integration

> **Status:** Open  
> **Date:** 2026-04-09  
> **Scope:** Infrastructure architecture for multi-tenant Obsidian Sync at 10-10,000+ users

---

## Executive Summary

This document evaluates architectures for scaling the DailyWerk Obsidian Sync
integration from a single-server MVP to a multi-node production deployment
serving thousands of tenants. The recommended path is an **ephemeral worker
model** that stores CLI state in S3 (Hetzner Object Storage) between sync
invocations, uses GoodJob's PostgreSQL advisory locks for per-tenant
concurrency control, and operates against fast local disk. This avoids the
cost explosion of container-per-tenant and the latency disaster of network
filesystems, while remaining compatible with the official `obsidian-headless`
CLI.

---

## Table of Contents

1. [Current Architecture](#1-current-architecture)
2. [Obsidian Sync Protocol Analysis](#2-obsidian-sync-protocol-analysis)
3. [Architecture Option 1: Network Storage](#3-architecture-option-1-network-storage)
4. [Architecture Option 2: Container-per-Sync](#4-architecture-option-2-container-per-sync)
5. [Architecture Option 3: S3 State Store (Recommended)](#5-architecture-option-3-s3-state-store-recommended)
6. [Architecture Option 4: Kubernetes-Native](#6-architecture-option-4-kubernetes-native)
7. [Architecture Option 5: Alternative Approaches](#7-architecture-option-5-alternative-approaches)
8. [Scaling Tiers](#8-scaling-tiers)
9. [Tradeoff Comparison](#9-tradeoff-comparison)
10. [Recommended Path](#10-recommended-path)
11. [Open Questions](#11-open-questions)
12. [Sources](#12-sources)

---

## 1. Current Architecture

### MVP Layout (Single Server)

```
GoodJob Worker (external mode)
  └── ObsidianSyncManager
        ├── shells out to `ob` CLI (obsidian-headless)
        ├── credentials via env vars (OBSIDIAN_EMAIL, OBSIDIAN_PASSWORD)
        └── uses unsetenv_others: true for isolation

Filesystem:
  {VAULT_LOCAL_BASE}/{workspace_id}/vaults/{vault_slug}/     ← vault content
  {VAULT_LOCAL_BASE}/{workspace_id}/config/{sync_config_id}/ ← XDG config dir
```

### What Lives in the XDG Config Directory

The `obsidian-headless` CLI stores its state in `$XDG_CONFIG_HOME` (defaults
to `~/.config/`). This includes:

- **Auth tokens** from `ob login` (session tokens, possibly refresh tokens)
- **Device registration** from `ob sync-setup` (device ID, vault binding)
- **Sync state** (last sync position, file hashes for delta calculation)
- **E2EE keys** (derived from the encryption password via scrypt)

This state is **essential** -- without it, every sync requires
re-authentication and full re-download. The auth tokens cannot be regenerated
without user interaction (especially with 2FA). This is the central constraint
that drives the architecture.

### Transition Underway

Moving from `ob sync --continuous` (long-running process) to periodic
`ob sync` (one-shot) via GoodJob cron. This is the right direction -- it
decouples sync from process lifecycle and makes the system amenable to the
scaling patterns below.

---

## 2. Obsidian Sync Protocol Analysis

### No Public API

Obsidian does not provide a public REST or WebSocket API for their sync
service. Their position is explicit: "Obsidian Sync is a service we intend to
keep first-party only for the foreseeable future."

### Reverse Engineering Attempts

| Project | Language | Status | Notes |
|---------|----------|--------|-------|
| [obi-sync](https://github.com/acheong08/obi-sync) | Go | Archived/broken | Obsidian actively patches against it. Broke on v1.4.11+. Cat-and-mouse game. |
| [rev-obsidian-sync](https://github.com/zyrouge/rev-obsidian-sync) | Go | Experimental | Fork of obi-sync, same fragility |
| [py-obisync](https://github.com/ShiinaRinne/py-obisync) | Python | Experimental | Quick rewrite, not production-grade |
| [vault-sync](https://github.com/alexjbarnes/vault-sync) | Go | Active (Feb 2026) | Most complete. WebSocket + E2EE (v0/v2/v3). OAuth 2.1. MCP server. |

**vault-sync** by alexjbarnes is the most interesting. It implements:
- Two-way encrypted sync via WebSocket
- AES-256-GCM + AES-SIV-CMAC encryption (versions 0, 2, 3)
- Scrypt key derivation for E2EE
- Three-way merge for `.md` files
- bbolt for local state persistence
- OAuth 2.1 with PKCE for auth

However, all reverse-engineered implementations carry existential risk.
Obsidian controls the protocol and has demonstrated willingness to break
third-party clients.

### The Official `obsidian-headless` CLI

Released 2026-02-27. Node.js 22+. This is the only supported path.

Key commands:
- `ob login` -- interactive auth (email/password/2FA)
- `ob sync-setup --vault "Name" --device-name "Name"` -- device registration
- `ob sync` -- one-shot bidirectional sync
- `ob sync --continuous` -- long-running watch mode

Limitations:
- No `--status` or `--dry-run` commands
- No official documentation on XDG directory structure
- No programmatic auth flow (credentials are interactive or env-var based)
- Device limit per account is not publicly documented (likely similar to
  desktop client limits)

### Protocol Conclusion

**Use the official CLI.** The protocol is proprietary and actively defended.
Reverse engineering is viable for experimentation but not for a production SaaS
with paying customers. The vault-sync Go project is worth monitoring as a
potential future alternative if it proves stable, but should not be depended on.

---

## 3. Architecture Option 1: Network Storage

**Concept:** Mount shared network storage (NFS/EFS/Ceph) so any worker node
can access any tenant's vault and config directory.

### Performance Analysis: The Small-File Problem

Obsidian vaults are collections of many small markdown files (typically
1-50KB each). A vault with 5,000 notes generates tens of thousands of
filesystem metadata operations during sync (`stat()`, `readdir()`, `open()`,
`close()`).

| Storage Type | Metadata Latency | 10K stat() ops | Verdict |
|-------------|-----------------|----------------|---------|
| Local NVMe/SSD | <0.1ms | ~1 second | Excellent |
| Local EBS (gp3) | ~0.5ms | ~5 seconds | Good |
| EFS (same-AZ) | 2-5ms | 20-50 seconds | Poor |
| EFS (cross-AZ) | 5-15ms | 50-150 seconds | Unusable |
| CephFS | 3-10ms | 30-100 seconds | Poor |
| NFS (self-hosted) | 1-5ms | 10-50 seconds | Marginal |

AWS explicitly warns against using EFS for workloads with many small files.
GitLab recommends against CephFS/GlusterFS for repository-style storage
(which is structurally similar to vault sync). Posit (RStudio) benchmarked
EFS specifically and concluded it is "particularly poorly suited for
latency-sensitive workloads reading thousands of small text files."

A subtle additional problem: Ruby applications on NFS can trigger excessive
`stat()` calls from bundler/require resolution, adding latency even before the
sync begins.

### Cost

- EFS: ~$0.30/GB/month (Standard), plus per-request charges
- Self-hosted NFS: server cost + maintenance burden
- Ceph: cluster of 3+ nodes minimum

### Verdict: NOT RECOMMENDED

Network filesystems are architecturally wrong for this workload. The
per-operation latency compounds to unacceptable levels. Even with tuning
(`read_ahead_kb`, NFSv4.1, same-AZ pinning), you are fighting the
fundamental physics of the storage layer.

---

## 4. Architecture Option 2: Container-per-Sync

**Concept:** Run a dedicated container for each VaultSyncConfig, either
long-running or ephemeral.

### Sub-options

#### 4a. Long-Running Container per Tenant (StatefulSet + `ob sync --continuous`)

Each tenant gets a Pod with a PersistentVolume. The CLI runs continuously.

**Pros:**
- Real-time sync (changes propagate in seconds)
- State is always warm on disk
- Simple mental model

**Cons:**
- Massive resource waste: most vaults sync infrequently
- At 1,000 tenants: 1,000 Pods = ~10 worker nodes minimum
- At 10,000 tenants: 10,000 Pods = ~100 nodes, $5-10K/month compute alone
- 10,000 PersistentVolumes = additional storage + IOPS costs
- etcd pressure from tracking 10K StatefulSets
- Node.js runtime overhead: ~50-128MB RAM per idle CLI process
- Kubernetes maxPods limit: 110 per node (default), requires tuning

#### 4b. Ephemeral Container per Sync (Kubernetes CronJob)

Spin up a container, sync, tear down. Requires state persistence elsewhere
(S3 -- making this a variant of Option 3).

**Pros:**
- No idle resource consumption
- Clean isolation between tenants

**Cons:**
- Container startup overhead: image pull + Node.js bootstrap = 5-30 seconds
- At 10,000 tenants syncing every 5 minutes: 2,000 concurrent containers
  during peak
- etcd overwhelmed by Job/Pod object churn
- `ttlSecondsAfterFinished` essential to avoid filling etcd
- Kubernetes CronJob has no native cross-job concurrency limiter
- Still need S3 for state, so all the complexity of Option 3 without the
  simplicity

#### 4c. Docker Compose with Dynamic Services

Not viable beyond a few dozen tenants. No orchestration, no auto-healing, no
resource management.

### Cost Model (StatefulSet at Scale)

| Scale | Pods | Min Nodes | Compute Cost | PV Storage | Total |
|-------|------|-----------|-------------|------------|-------|
| 100 | 100 | 2 | ~$150/mo | ~$50/mo | ~$200/mo |
| 1,000 | 1,000 | 10-15 | ~$1,500/mo | ~$500/mo | ~$2,000/mo |
| 10,000 | 10,000 | 100+ | ~$8,000/mo | ~$3,000/mo | ~$11,000/mo |

These costs are for compute and storage only, not including the platform
engineering time to operate the cluster.

### Verdict: NOT RECOMMENDED at scale

Container-per-tenant provides excellent isolation but terrible unit economics.
The 4b variant (ephemeral containers + S3) is essentially a more expensive
version of Option 3.

---

## 5. Architecture Option 3: S3 State Store (Recommended)

**Concept:** Store CLI state (XDG config directory) and vault content in S3
(Hetzner Object Storage). On each sync: download state to local disk, run
`ob sync`, upload state back. Use GoodJob advisory locks for per-tenant
concurrency.

### How It Works

```
                    ┌─────────────────────────────────────────┐
                    │           GoodJob Worker Pool            │
                    │  (stateless Rails workers, local disk)   │
                    └───────────┬─────────────┬───────────────┘
                                │             │
                    ┌───────────▼──┐   ┌──────▼───────────┐
                    │  PostgreSQL  │   │  S3 / Hetzner    │
                    │  - job queue │   │  Object Storage  │
                    │  - advisory  │   │  - config.tar.gz │
                    │    locks     │   │  - vault.tar.gz  │
                    │  - metadata  │   │  (per tenant)    │
                    └──────────────┘   └──────────────────┘
```

### Sync Flow (Step by Step)

1. **GoodJob cron** enqueues `ObsidianSyncJob(sync_config_id, workspace_id:)`
   every N minutes.
2. **GoodJob concurrency control** evaluates
   `concurrency_key: -> { "obsidian_sync_#{sync_config_id}" }` with
   `perform_limit: 1`. If a job is already running for this tenant, the new
   job waits or is discarded. PostgreSQL advisory locks enforce this at the
   database level -- no race conditions.
3. **State retrieval:** Worker downloads two archives from S3:
   - `workspaces/{workspace_id}/sync-state/{sync_config_id}/config.tar.gz`
     (XDG config: auth tokens, device registration, sync position)
   - `workspaces/{workspace_id}/sync-state/{sync_config_id}/vault.tar.gz`
     (vault content: markdown files)
4. **Extraction:** Archives are extracted to a temp directory on fast local
   disk (SSD/NVMe). `XDG_CONFIG_HOME` is set to point there.
5. **Sync execution:** Worker shells out to `ob sync` with isolated env vars
   (same pattern as current `ObsidianSyncManager`).
6. **State persistence:** On successful exit, worker re-archives the
   directories and uploads back to S3 (overwriting previous versions).
7. **Cleanup:** Temp directories are deleted. GoodJob releases the advisory
   lock.
8. **Error handling:** On CLI failure, check exit code. If auth expired, set
   `process_status: "auth_required"` and notify user. If transient error,
   increment `consecutive_failures` and retry with backoff.

### Race Condition Analysis

The primary risk with S3 state packing is the "lost update" problem: two
workers download the same state, both sync, and one overwrites the other's
changes.

**GoodJob eliminates this entirely.** The `perform_limit: 1` with
`concurrency_key` uses PostgreSQL session-level advisory locks. Only one job
per sync_config can execute at a time, enforced at the database level. This is
the same locking mechanism Terraform uses (via DynamoDB, now S3 native locks)
but we get it for free from our existing PostgreSQL + GoodJob infrastructure.

### What About State Drift During Sync?

If the user modifies their vault from a phone while a sync is running on our
server, Obsidian Sync handles this at the protocol level -- the CLI
reconciles remote changes during `ob sync`. The re-uploaded state will reflect
the merged result.

### Compression and Transfer Overhead

| Vault Size | Files | Compressed Size | S3 Download | S3 Upload | Total Overhead |
|-----------|-------|-----------------|-------------|-----------|----------------|
| 10MB | 500 notes | ~3MB | <1s | <1s | ~2s |
| 100MB | 5,000 notes | ~30MB | ~2s | ~2s | ~4s |
| 500MB | 10,000 notes + attachments | ~150MB | ~5s | ~5s | ~10s |
| 1GB | Large vault with media | ~400MB | ~10s | ~10s | ~20s |

Over Hetzner's internal network (10 Gbps), even large vaults transfer in
seconds. The compression/decompression CPU cost is negligible (tar+gzip on
modern hardware: ~500MB/s).

### Cost at Scale

| Scale | S3 Storage | S3 Requests | Compute (shared pool) | Total |
|-------|-----------|-------------|----------------------|-------|
| 100 | ~$1/mo | ~$2/mo | ~$50/mo (2 workers) | ~$53/mo |
| 1,000 | ~$10/mo | ~$20/mo | ~$150/mo (4 workers) | ~$180/mo |
| 10,000 | ~$100/mo | ~$200/mo | ~$500/mo (8-10 workers) | ~$800/mo |

Compare this to the $11,000/mo for container-per-tenant at 10,000 users.

### Optimization: Delta State Storage

Instead of re-uploading the entire vault on every sync, store only the XDG
config directory in S3 (small, ~1MB) and keep vault content in the existing
VaultS3Service (which already syncs vault files to S3 with SSE-C encryption).
On sync:

1. Download config state from S3 (~1MB)
2. Reconstruct vault from VaultS3Service (or from PostgreSQL file metadata +
   S3 content)
3. Run `ob sync`
4. Upload changed files back via VaultS3Service
5. Upload config state back to S3

This reduces transfer overhead dramatically for repeat syncs where only a few
files changed. The existing `VaultS3SyncJob` infrastructure already handles
per-file S3 sync.

### Verdict: RECOMMENDED

Best balance of cost, complexity, reliability, and scaling characteristics.
Uses existing infrastructure (PostgreSQL, GoodJob, S3). No new systems to
operate.

---

## 6. Architecture Option 4: Kubernetes-Native

**Concept:** Use K8s primitives (StatefulSets, CronJobs, Operators) as the
primary orchestration layer.

### 6a. StatefulSets + PersistentVolumes

Already covered in Option 2. Not economically viable at scale.

### 6b. K8s CronJobs + S3 State

This is Option 3 but with Kubernetes CronJobs instead of GoodJob. Comparison:

| Aspect | GoodJob Cron | K8s CronJob |
|--------|-------------|-------------|
| Concurrency control | PostgreSQL advisory locks (rock solid) | `concurrencyPolicy: Forbid` (per CronJob only) |
| Cross-job concurrency | Native via `concurrency_key` | Not supported natively |
| State visibility | Rails models, admin UI | kubectl + separate monitoring |
| Error handling | Ruby exception handling, retry policies | Exit codes, separate alerting |
| Object overhead | Zero (just database rows) | Pod + Job objects in etcd |
| Scaling to 10K | Trivial (just enqueue more jobs) | etcd pressure, API server load |
| Operational burden | Part of existing Rails stack | Separate K8s expertise required |

GoodJob wins on every dimension except isolation (K8s containers are more
isolated than GoodJob threads/processes).

### 6c. Custom Operator (ObsidianSync CRD)

An Operator written in Go that manages `ObsidianSyncConfig` custom resources:

```yaml
apiVersion: dailywerk.com/v1
kind: ObsidianSync
metadata:
  name: tenant-abc123
spec:
  syncConfigId: "uuid-here"
  schedule: "*/5 * * * *"
  vaultName: "My Second Brain"
```

**This is over-engineering for this problem.** It splits domain logic between
Ruby (Rails) and Go (Operator), requires specialized platform engineering,
and solves a problem that GoodJob already handles natively. Only justified if
DailyWerk becomes primarily an infrastructure product, which it is not.

### Verdict: SKIP

Kubernetes-native approaches add complexity without proportional benefit. The
application layer (GoodJob) is the right place for this orchestration.

---

## 7. Architecture Option 5: Alternative Approaches

### 7a. Direct Protocol Implementation (WebSocket Client)

Build a native Ruby or Go client that speaks the Obsidian Sync WebSocket
protocol directly, bypassing the CLI entirely.

**The vault-sync project** (Go, by alexjbarnes) demonstrates this is
technically feasible. It implements:
- WebSocket connection to `wss://sync-*.obsidian.md`
- E2EE encryption/decryption (AES-256-GCM, scrypt)
- Three-way merge for markdown files
- bbolt for local sync state

**Pros:**
- No Node.js dependency (eliminates 50-128MB RAM per sync)
- Sub-second sync startup (no CLI bootstrap)
- Fine-grained control over sync behavior
- Could run as a library within the GoodJob worker process

**Cons:**
- Obsidian actively patches against third-party clients
- Protocol is undocumented and changes without notice
- E2EE implementation must be perfect (security risk)
- vault-sync is a single developer's project (bus factor = 1)
- Legal/ToS risk

**Recommendation:** Monitor vault-sync. If it proves stable over 6+ months
and builds a community, consider forking or wrapping it. Do not depend on it
for production today.

### 7b. FUSE + Object Storage

Mount S3 via FUSE (s3fs, goofys, JuiceFS) so the CLI thinks it is on local
disk while data lives in object storage.

| FUSE Client | Small-File Performance | POSIX Compliance | Maturity |
|------------|----------------------|-----------------|----------|
| s3fs | Very slow (~6x slower than local) | Partial | Mature but slow |
| goofys | Moderate (high FUSE overhead) | Partial | Stale (Go FUSE lib issues) |
| JuiceFS | Good (~10x faster than s3fs) | Full POSIX | Production-grade, needs Redis/MySQL |
| AWS S3 Files | Native NFS on S3 (new in 2026) | NFS v4.1 | Very new, AWS-only |

**JuiceFS** is the most viable option. It separates metadata (Redis/MySQL)
from data (S3), providing near-local metadata performance. But it requires
deploying and maintaining a metadata server cluster.

**AWS S3 Files** is interesting but AWS-only and very new. Not available on
Hetzner.

**Verdict:** FUSE is a poor fit. The overhead of translating POSIX ops to S3
API calls is fundamentally wrong for a many-small-file workload. The
pack/unpack pattern (Option 3) is simpler and faster.

### 7c. Dedicated Sync Microservice (Go/Rust)

Replace the Ruby `ObsidianSyncManager` + `ob` CLI with a dedicated
microservice that either:
- Wraps the official CLI more efficiently (managing XDG state, compression)
- Implements the protocol directly (risky, per 7a above)

**Not justified yet.** The overhead of shelling out to `ob` from Ruby is
minimal (fork + exec, ~50ms). A microservice introduces deployment complexity,
API contracts, and a second language in the stack without proportional benefit.
Reconsider if sync becomes the bottleneck at 5,000+ tenants.

### 7d. Obsidian LiveSync (CouchDB-based)

An alternative community plugin ([obsidian-livesync](https://github.com/vrtmrz/obsidian-livesync))
uses CouchDB instead of Obsidian Sync. Users install the plugin and point it
at a CouchDB instance you host. The MCP project
[obsidian-sync-mcp](https://github.com/es617/obsidian-sync-mcp) reads from
CouchDB directly.

**Pros:**
- You control the sync infrastructure entirely
- No dependency on Obsidian's proprietary protocol
- CouchDB is designed for replication

**Cons:**
- Requires users to install a plugin and configure it (friction)
- Different from the official Obsidian Sync (users may already be paying for it)
- CouchDB operational overhead
- Not compatible with users who want to keep using official Obsidian Sync

**Verdict:** Worth offering as an alternative for power users, but cannot
replace Obsidian Sync support.

---

## 8. Scaling Tiers

### Tier 1: 1-10 Users (Current MVP)

**Architecture:** Single server, local disk, GoodJob cron.

What we have today, with the one-shot `ob sync` migration completing. No S3
state packing needed -- state stays on local disk. The only server that runs
sync is the same server that has the files.

**Cost:** ~$0 incremental (existing infrastructure)
**Complexity:** Minimal
**Risk:** Server loss = loss of sync state (but vault content is in S3 via
VaultS3Service and on Obsidian's servers)

### Tier 2: 10-100 Users (Single Server, S3 State)

**Architecture:** Single server + S3 state backup.

Start backing up XDG config directories to S3 after each sync. This is a
one-way insurance policy: if the server dies, state can be restored to a new
server. No architectural change to the sync flow itself.

Implement GoodJob concurrency control (`perform_limit: 1` per sync_config).
Add staggered scheduling (not all syncs at :00, distribute across the
interval).

**Cost:** ~$5/mo for S3
**Complexity:** Low (add tar/upload step after sync)
**Risk:** Low

### Tier 3: 100-1,000 Users (Multi-Worker, Full S3 State Store)

**Architecture:** Multiple GoodJob worker processes/nodes, S3 as the primary
state store.

This is the full Option 3 implementation. Any worker can sync any tenant by
downloading state from S3. Workers are stateless and horizontally scalable.

Key implementation work:
- Pack/unpack XDG config to S3 (before/after every sync)
- Pack/unpack vault content to S3 (or use VaultS3Service for per-file sync)
- Ensure `XDG_CONFIG_HOME` is set correctly per-sync invocation
- Temp directory cleanup (even on crash -- use `at_exit` or `ensure`)
- Monitoring: sync duration, failure rate, queue depth per tenant

**Cost:** ~$200/mo
**Complexity:** Medium
**Risk:** Medium (S3 as critical path for sync state)

### Tier 4: 1,000-10,000+ Users (Optimized Worker Pool)

**Architecture:** Dedicated sync worker pool with optimizations.

Same as Tier 3, with:
- **Delta state sync:** Only upload changed files, not full vault archives.
  Use checksums to detect changes.
- **Warm cache:** Keep frequently-syncing tenants' state on local disk as a
  cache, with S3 as the canonical store. LRU eviction when disk fills.
- **Priority queues:** Separate GoodJob queues for urgent syncs (user-initiated)
  vs. background syncs (cron).
- **Adaptive scheduling:** Reduce sync frequency for inactive vaults. Increase
  for vaults with recent activity.
- **Dedicated worker nodes:** Workers with NVMe local storage, optimized for
  the pack/unpack/sync cycle.
- **Parallel sync within a vault:** If `ob` supports it in the future, sync
  sub-directories in parallel.

At this scale, consider:
- Is the `ob` CLI the bottleneck? Profile sync times. If yes, evaluate the
  Go-based vault-sync library.
- Are Obsidian's servers throttling? Monitor for rate limits or device
  registration caps.
- Is S3 transfer a bottleneck? Unlikely (internal network), but monitor.

**Cost:** ~$800/mo
**Complexity:** High
**Risk:** Need to understand Obsidian's undocumented per-account limits

---

## 9. Tradeoff Comparison

| Criteria | Network FS | Container/Tenant | S3 State Store | K8s Native | Direct Protocol |
|----------|-----------|-----------------|----------------|-----------|----------------|
| **Cost at 10K users** | $2-5K/mo | $11K/mo | $800/mo | $3-8K/mo | $500/mo |
| **Latency (sync start)** | High (NFS ops) | Low (warm state) | Medium (S3 download) | Medium | Very low |
| **Operational complexity** | Medium | Very high | Low | Very high | Very high |
| **Isolation** | Poor | Excellent | Good (advisory locks) | Excellent | N/A |
| **Uses existing infra** | No | No | Yes | No | No |
| **Vendor risk** | None | None | None | None | High (protocol changes) |
| **Horizontal scaling** | Limited | Complex | Trivial | Complex | Trivial |
| **Data durability** | Depends on FS | PV dependent | S3 (11 nines) | PV dependent | S3 (11 nines) |

---

## 10. Recommended Path

### Phase 1: Immediate (Tier 1-2, current)

Complete the `ob sync --continuous` to `ob sync` (one-shot) migration. This is
already underway. Add GoodJob concurrency control:

```ruby
class ObsidianSyncJob < ApplicationJob
  include WorkspaceScopedJob
  include GoodJob::ActiveJobExtensions::Concurrency

  good_job_control_concurrency_with(
    perform_limit: 1,
    key: -> { "obsidian_sync_#{arguments.first}" }
  )

  def perform(sync_config_id, workspace_id:)
    # existing sync logic
  end
end
```

Start backing up XDG config directories to S3 after each successful sync.
This is insurance, not a workflow change.

### Phase 2: Multi-Worker (Tier 3, 100+ users)

Implement the full S3 state store pattern:

1. Before sync: download config + vault state from S3 to local temp dir
2. Set `XDG_CONFIG_HOME` to temp dir
3. Run `ob sync`
4. After sync: upload state back to S3
5. Clean up temp dir

This decouples sync from any specific server. Workers become stateless.

### Phase 3: Optimization (Tier 4, 1,000+ users)

Add delta state sync, warm caching, adaptive scheduling, priority queues.
Profile and optimize. Consider the Go-based vault-sync library if the CLI
becomes the bottleneck.

### What NOT to Build

- Do not build a Kubernetes Operator
- Do not use network filesystems (EFS/NFS/Ceph) for vault storage
- Do not use FUSE + object storage
- Do not reverse-engineer the Obsidian Sync protocol (yet)
- Do not build a dedicated microservice (yet)

---

## 11. Open Questions

1. **Obsidian device limits:** How many devices can be registered per Obsidian
   Sync account? If a user has 5 devices and we register a 6th (headless),
   does it fail? Does headless count as a device? Need to test empirically.

2. **Auth token expiry:** How long do `ob login` tokens last? If they expire
   after N days, the cron sync will fail and the user needs to re-authenticate.
   Need to test and build a re-auth flow.

3. **Rate limiting:** Does Obsidian throttle sync frequency? If we sync every
   minute for 10,000 users, that is ~167 syncs/second against their servers.
   Need to monitor and potentially implement client-side rate limiting.

4. **Vault size limits:** Very large vaults (1GB+) may make the S3
   pack/unpack cycle too slow. The delta sync optimization (Phase 3) is
   essential for these cases.

5. **`ob sync` exit codes:** The CLI does not document its exit codes. Need to
   catalog them to distinguish auth failures from transient errors from
   corruption.

6. **Obsidian ToS:** Does using `obsidian-headless` in a multi-tenant SaaS
   context (where our server syncs on behalf of users who provide their own
   credentials) comply with Obsidian's Terms of Service? Each user has their
   own Obsidian Sync subscription; we are acting as their agent.

7. **Hetzner Object Storage performance:** The cost estimates assume Hetzner
   S3-compatible storage. Need to benchmark actual transfer speeds and request
   latency from Hetzner workers to Hetzner Object Storage.

---

## 12. Sources

### Obsidian Sync & Protocol
- [obsidian-headless CLI (official)](https://github.com/obsidianmd/obsidian-headless)
- [Obsidian CLI documentation](https://obsidian.md/cli)
- [Obsidian Headless Sync docs](https://help.obsidian.md/sync/headless)
- [obi-sync (reverse-engineered, archived)](https://github.com/acheong08/obi-sync)
- [vault-sync (Go, WebSocket + MCP)](https://github.com/alexjbarnes/vault-sync)
- [obsidian-headless-sync-docker](https://github.com/Belphemur/obsidian-headless-sync-docker)
- [Obsidian Sync plans and limits](https://help.obsidian.md/Plans+and+storage+limits)
- [Obsidian Forum: Sync API request](https://forum.obsidian.md/t/sync-api-way-to-access-syncd-data/25371)

### Kubernetes & Container Orchestration
- [Kubernetes StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/stateful-sets/)
- [Kubernetes CronJobs](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
- [Kubernetes Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)
- [K8s Pod Overhead](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-overhead/)
- [K8s CronJob concurrency issue #91652](https://github.com/kubernetes/kubernetes/issues/91652)

### Storage & Filesystems
- [EFS performance tips (AWS)](https://docs.aws.amazon.com/efs/latest/ug/performance-tips.html)
- [EFS vs NFS for Kubernetes (Posit)](https://www.cynkra.com/blog/2022-09-14-rstudio-efs-nfs/)
- [Challenges of EFS (Convox)](https://www.convox.com/blog/challenges-of-efs)
- [JuiceFS vs S3FS](https://juicefs.com/docs/community/comparison/juicefs_vs_s3fs/)
- [AWS S3 Files announcement](https://thenewstack.io/aws-s3-files-filesystem/)
- [S3 native state locking (Terraform)](https://www.bschaatsbergen.com/s3-native-state-locking)

### Multi-Tenant SaaS Patterns
- [Nylas IMAP sync architecture](https://www.nylas.com/blog/guide-to-imap-send-and-sync-mail/)
- [Nylas sync engine (GitHub)](https://github.com/nylas/sync-engine)
- [GoodJob advisory locks](https://github.com/bensheldon/good_job)
- [Multi-tenant SaaS architecture (WorkOS)](https://workos.com/blog/developers-guide-saas-multi-tenant-architecture)

### Alternative Sync Approaches
- [obsidian-livesync (CouchDB)](https://github.com/vrtmrz/obsidian-livesync)
- [obsidian-sync-mcp (CouchDB MCP)](https://github.com/es617/obsidian-sync-mcp)
