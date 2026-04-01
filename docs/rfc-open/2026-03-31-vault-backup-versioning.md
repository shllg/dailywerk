---
type: rfc
title: Vault Backup & Versioning
created: 2026-03-31
updated: 2026-03-31
status: draft
implements:
  - prd/01-platform-and-infrastructure
  - prd/06-deployment-hetzner
depends_on:
  - rfc/2026-03-30-workspace-isolation
  - rfc/2026-03-31-vault-filesystem
phase: 2
---

# RFC: Vault Backup & Versioning

## Context

Vault data is the most valuable asset in DailyWerk — user's personal knowledge accumulated over months or years. Data loss is unacceptable. This RFC implements application-level file versioning, point-in-time snapshots, and a backup strategy that aligns with the deployment architecture ([PRD 06](../prd/06-deployment-hetzner.md)).

### What This RFC Covers

- `vault_file_versions` table for application-level file history
- `vault_snapshots` table for point-in-time vault snapshots
- VaultVersioningService (create versions before overwrites, content-hash dedup)
- VaultSnapshotService (create/restore snapshots via S3 manifests)
- API endpoints for file history and snapshot management
- Version retention and cleanup
- Backup strategy (restic integration, disaster recovery)
- SSE-C key recovery procedures
- Local dev and production configuration

### What This RFC Does NOT Cover

- Vault filesystem, storage, indexing — see [RFC: Vault Filesystem](./2026-03-31-vault-filesystem.md)
- Obsidian Sync — see [RFC: Obsidian Sync](./2026-03-31-obsidian-sync.md)
- User-facing undo/redo in the dashboard (future — uses version + snapshot restore APIs)
- Cross-vault deduplication / content-addressable storage (deferred)
- Continuous data protection / WAL-based recovery (over-engineering for MVP)

### Why Application-Level Versioning

Hetzner Object Storage supports S3 bucket versioning, but:

1. It must be enabled via CLI (`mc version enable`), not the console UI
2. Behavior and reliability on Hetzner's Ceph-based storage is not as battle-tested as AWS S3 — if reliability becomes an issue, the S3 backend can be swapped to Cloudflare R2, DigitalOcean Spaces, or any S3-compatible provider without changing the application versioning logic
3. Application-level versioning gives full control over retention, deduplication, restore UX, and audit trail
4. Version metadata (who changed it, why, content hash) lives in PostgreSQL alongside the rest of the data model

S3 bucket versioning can be enabled as an additional safety net, but the application does not depend on it. The `VaultS3Service` is provider-agnostic — switching from Hetzner to another S3-compatible backend is a config change (`vault_s3_endpoint`, `vault_s3_region`, credentials).

### Two-Tier Design: Backup (Always-On) vs Versioning (Feature-Flagged)

Vault data safety has two distinct tiers:

1. **Backup** (always on, every workspace): S3 as canonical store, VaultS3SyncJob every 5 minutes, PostgreSQL backup via restic, disaster recovery. This is non-negotiable — every user gets this regardless of plan. Data loss is never acceptable.

2. **File versioning** (feature-flagged, subscription-gated): Version history per file, snapshot creation/restore, version diff view, retention policies. This is a premium feature — it costs S3 storage and API calls proportional to edit frequency. Gated via a workspace feature flag (`workspace.features.vault_versioning`) that is enabled by subscription plan (via Stripe, see [PRD 04](../prd/04-billing-and-operations.md)).

When versioning is disabled, `VaultVersioningService.create_version` is a no-op. The `VaultFileChangedJob` skips the version-creation step. Snapshots API returns 403. Backups and S3 sync continue regardless.

---

## 1. Prerequisites

- [RFC: Vault Filesystem](./2026-03-31-vault-filesystem.md) implemented (vaults, vault_files, VaultS3Service, VaultFileChangedJob)
- GoodJob concurrency control configured on VaultFileChangedJob (perform_limit: 1 per file key)

---

## 2. Database Schema

### 2.1 Vault File Versions Table

```ruby
class CreateVaultFileVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :vault_file_versions, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :vault_file, type: :uuid, null: false, foreign_key: true
      t.references :workspace,  type: :uuid, null: false, foreign_key: true  # Denormalized for RLS
      t.string   :content_hash, null: false                    # SHA-256 of the versioned content
      t.bigint   :size_bytes,   null: false
      t.string   :s3_version_key, null: false                  # S3 key: workspaces/{wid}/versions/{vault_slug}/{path}/v{n}_{ts}
      t.string   :change_source, default: "system"             # agent, obsidian_sync, api, restore, system
      t.text     :change_summary                               # Optional: what changed (from agent context)
      t.integer  :version_number, null: false                  # Sequential per file, starting at 1
      t.timestamps

      t.index [:vault_file_id, :created_at]
      t.index [:vault_file_id, :version_number], unique: true
      t.index [:workspace_id, :created_at]
      t.index :content_hash
    end

    safety_assured do
      execute "ALTER TABLE vault_file_versions ENABLE ROW LEVEL SECURITY;"
      execute "ALTER TABLE vault_file_versions FORCE ROW LEVEL SECURITY;"
      execute <<~SQL
        CREATE POLICY workspace_isolation ON vault_file_versions
          FOR ALL TO app_user
          USING (workspace_id::text = current_setting('app.current_workspace_id', true))
          WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
      SQL
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_file_versions TO app_user;"
    end
  end
end
```

### 2.2 Vault Snapshots Table

```ruby
class CreateVaultSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :vault_snapshots, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
      t.references :vault,     type: :uuid, null: false, foreign_key: true
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string   :snapshot_type, null: false, default: "automatic"  # automatic, manual, pre_restore
      t.string   :status,       default: "pending"                  # pending, creating, complete, failed
      t.integer  :file_count
      t.bigint   :total_size_bytes
      t.string   :s3_manifest_key                                   # S3 key to manifest JSON
      t.text     :description
      t.timestamps

      t.index [:vault_id, :created_at]
      t.index [:workspace_id, :snapshot_type]
    end

    safety_assured do
      execute "ALTER TABLE vault_snapshots ENABLE ROW LEVEL SECURITY;"
      execute "ALTER TABLE vault_snapshots FORCE ROW LEVEL SECURITY;"
      execute <<~SQL
        CREATE POLICY workspace_isolation ON vault_snapshots
          FOR ALL TO app_user
          USING (workspace_id::text = current_setting('app.current_workspace_id', true))
          WITH CHECK (workspace_id::text = current_setting('app.current_workspace_id', true));
      SQL
      execute "GRANT SELECT, INSERT, UPDATE, DELETE ON vault_snapshots TO app_user;"
    end
  end
end
```

---

## 3. Models

### 3.1 VaultFileVersion

```ruby
# app/models/vault_file_version.rb
# A point-in-time version of a vault file, stored in S3.
class VaultFileVersion < ApplicationRecord
  include WorkspaceScoped

  belongs_to :vault_file

  validates :content_hash, presence: true
  validates :size_bytes, presence: true
  validates :s3_version_key, presence: true
  validates :version_number, presence: true, uniqueness: { scope: :vault_file_id }
  validates :change_source, inclusion: { in: %w[agent obsidian_sync api restore system] }
end
```

### 3.2 VaultSnapshot

```ruby
# app/models/vault_snapshot.rb
# A point-in-time snapshot of an entire vault, represented as a manifest of file content hashes.
class VaultSnapshot < ApplicationRecord
  include WorkspaceScoped

  belongs_to :vault

  validates :snapshot_type, presence: true, inclusion: { in: %w[automatic manual pre_restore] }
  validates :status, inclusion: { in: %w[pending creating complete failed] }

  scope :complete, -> { where(status: "complete") }
end
```

### 3.3 Model Associations

```ruby
# app/models/vault_file.rb (add)
has_many :versions, class_name: "VaultFileVersion", dependent: :destroy

# app/models/vault.rb (add)
has_many :snapshots, class_name: "VaultSnapshot", dependent: :destroy
```

---

## 4. Service Layer

### 4.1 VaultVersioningService — Create Versions Before Overwrites

```ruby
# app/services/vault_versioning_service.rb
# Creates application-level versions before file overwrites. Uses advisory locks
# to prevent concurrent versioning and DB transactions for S3/DB consistency.
class VaultVersioningService
  def initialize(vault:)
    @vault = vault
    @s3 = VaultS3Service.new(vault)
  end

  # Creates a version of the current file state before it is overwritten.
  # Called by VaultFileChangedJob when processing a "modify" event.
  #
  # @param vault_file [VaultFile] the file about to be overwritten
  # @param change_source [String] what triggered the change (agent, obsidian_sync, api)
  # Concurrency: VaultFileChangedJob uses GoodJob perform_limit: 1 per file,
  # preventing concurrent version creation. No advisory locks needed
  # (advisory locks are unsafe under Falcon's fiber model).
  def create_version(vault_file, change_source: "system")
    # No previous content to version (new file)
    return if vault_file.content_hash.blank?

    # Content-hash dedup: skip if this exact content is already versioned
    return if vault_file.versions.exists?(content_hash: vault_file.content_hash)

    version_number = (vault_file.versions.maximum(:version_number) || 0) + 1
    version_key = build_version_key(vault_file, version_number)

    # Create DB record first, then sync to S3.
    # S3 failure leaves an orphaned DB record (cleaned by VaultVersionCleanupJob).
    # This is safer than S3-inside-transaction which risks DB connection pool
    # exhaustion under Falcon's fiber concurrency model.
    version = vault_file.versions.create!(
      workspace: @vault.workspace,
      content_hash: vault_file.content_hash,
      size_bytes: vault_file.size_bytes || 0,
      s3_version_key: version_key,
      version_number: version_number,
      change_source: change_source
    )

    begin
      @s3.copy_to_version(vault_file.path, version_key)
    rescue => e
      Rails.logger.error "[VaultVersioning] S3 copy failed for version #{version.id}: #{e.message}"
      # DB record exists but S3 object doesn't — VaultVersionCleanupJob handles orphans
    end
  end

  # Restores a specific version of a file.
  # Creates a pre-restore version of the current state first.
  #
  # @param vault_file [VaultFile] the file to restore
  # @param version [VaultFileVersion] the version to restore to
  def restore_version(vault_file, version)
    # Save current state before restoring
    create_version(vault_file, change_source: "restore")

    # Read versioned content from S3
    content = @s3.get_by_key(version.s3_version_key)

    # Write to local checkout — inotify triggers re-indexing and S3 sync
    VaultFileService.new(vault: @vault).write(vault_file.path, content)
  end

  private

  def build_version_key(vault_file, version_number)
    timestamp = Time.current.strftime("%Y%m%d%H%M%S")
    "workspaces/#{@vault.workspace_id}/versions/#{@vault.slug}/#{vault_file.path}/v#{version_number}_#{timestamp}"
  end
end
```

**Design decisions**:

1. **GoodJob concurrency control**: `VaultFileChangedJob` uses `perform_limit: 1` per file key, preventing concurrent version creation. Advisory locks are avoided because they are unsafe under Falcon's fiber model.
2. **DB record first, then S3**: The DB record is created outside a transaction, then S3 is called separately. If S3 fails, the orphaned DB record is cleaned by `VaultVersionCleanupJob`. This avoids holding a DB connection open during S3 I/O, which would risk connection pool exhaustion under Falcon's fiber concurrency.
3. **Content-hash deduplication**: Identical content is not versioned twice. Saves S3 storage and prevents noise in version history from no-op saves.

### 4.2 VaultSnapshotService — Point-in-Time Snapshots

```ruby
# app/services/vault_snapshot_service.rb
# Creates and restores point-in-time vault snapshots.
# A snapshot is a manifest of file paths + content hashes, stored as JSON in S3.
class VaultSnapshotService
  def initialize(vault:)
    @vault = vault
    @s3 = VaultS3Service.new(vault)
  end

  # Creates a snapshot of the current vault state.
  #
  # @param type [String] automatic, manual, or pre_restore
  # @param description [String] optional description
  # @return [VaultSnapshot] the created snapshot
  def create_snapshot(type: "automatic", description: nil)
    snapshot = @vault.snapshots.create!(
      workspace: @vault.workspace,
      snapshot_type: type,
      status: "creating",
      description: description
    )

    manifest = @vault.vault_files.map do |vf|
      {
        path: vf.path,
        content_hash: vf.content_hash,
        size_bytes: vf.size_bytes,
        file_type: vf.file_type,
        last_modified: vf.last_modified&.iso8601
      }
    end

    manifest_key = "workspaces/#{@vault.workspace_id}/snapshots/#{@vault.slug}/#{snapshot.id}.json"
    @s3.instance_variable_get(:@client).put_object(
      bucket: Rails.application.config.x.vault_s3_bucket,
      key: manifest_key,
      body: manifest.to_json,
      **@s3.send(:sse_c_headers)
    )

    snapshot.update!(
      status: "complete",
      file_count: manifest.size,
      total_size_bytes: manifest.sum { |f| f[:size_bytes].to_i },
      s3_manifest_key: manifest_key
    )

    snapshot
  rescue => e
    snapshot&.update!(status: "failed")
    raise
  end

  # Restores a vault to a previous snapshot state (full or selective).
  # Creates a pre_restore snapshot of the current state first.
  #
  # @param snapshot [VaultSnapshot] the snapshot to restore
  # @param paths [Array<String>, nil] optional list of file paths to restore.
  #   If nil, restores the entire vault. If provided, only restores the listed files.
  #   This allows users to selectively roll back specific files without affecting others.
  def restore_snapshot(snapshot, paths: nil)
    raise ArgumentError, "Cannot restore incomplete snapshot" unless snapshot.status == "complete"

    # Safety: snapshot current state before restoring
    scope_desc = paths ? "#{paths.size} files" : "full vault"
    create_snapshot(type: "pre_restore", description: "Auto-snapshot before #{scope_desc} restore to #{snapshot.id}")

    # Read manifest
    resp = @s3.instance_variable_get(:@client).get_object(
      bucket: Rails.application.config.x.vault_s3_bucket,
      key: snapshot.s3_manifest_key,
      **@s3.send(:sse_c_headers)
    )
    manifest = JSON.parse(resp.body.read)

    # Filter manifest to requested paths if selective restore
    if paths.present?
      path_set = paths.to_set
      manifest = manifest.select { |entry| path_set.include?(entry["path"]) }
    end

    versioning = VaultVersioningService.new(vault: @vault)

    manifest.each do |entry|
      vault_file = @vault.vault_files.find_by(path: entry["path"])
      next unless vault_file

      # Find the version matching the snapshot's content hash
      version = vault_file.versions.find_by(content_hash: entry["content_hash"])
      next unless version

      # Only restore if current content differs
      next if vault_file.content_hash == entry["content_hash"]

      versioning.restore_version(vault_file, version)
    end

    # Trigger full re-index after restore
    VaultFullReindexJob.perform_later(@vault.id, workspace_id: @vault.workspace_id)
  end
end
```

---

## 5. Integration with VaultFileChangedJob

The versioning service hooks into the existing `VaultFileChangedJob` (from [RFC: Vault Filesystem](./2026-03-31-vault-filesystem.md)). Before processing a "modify" event, the job creates a version of the current file state.

Add to `VaultFileChangedJob#process_file`, before the file is updated:

```ruby
def process_file(vault, path)
  file_service = VaultFileService.new(vault: vault)
  content = file_service.read(path)
  content_hash = Digest::SHA256.hexdigest(content)

  vault_file = vault.vault_files.find_or_initialize_by(path: path)

  # Skip if content is unchanged
  return if vault_file.persisted? && vault_file.content_hash == content_hash

  # >>> CREATE VERSION BEFORE OVERWRITE (feature-flagged) <<<
  if vault_file.persisted? && vault_file.content_hash.present? && vault.workspace.feature?(:vault_versioning)
    VaultVersioningService.new(vault: vault).create_version(vault_file)
  end

  # ... rest of existing process_file logic (assign attributes, save, rechunk, relink)
end
```

---

## 6. API Endpoints

### 6.1 File Version History

```ruby
# app/controllers/api/v1/vault_file_versions_controller.rb
# Lists and restores file versions. Requires vault_versioning feature flag.
class Api::V1::VaultFileVersionsController < ApplicationController
  before_action :require_versioning_feature!

  # GET /api/v1/vaults/:vault_id/files/:vault_file_id/versions
  def index
    vault_file = find_vault_file
    versions = vault_file.versions.order(version_number: :desc).limit(50)
    render json: versions.map { |v| version_json(v) }
  end

  # GET /api/v1/vaults/:vault_id/files/:vault_file_id/versions/:id
  def show
    vault_file = find_vault_file
    version = vault_file.versions.find(params[:id])
    content = VaultS3Service.new(vault_file.vault).get_by_key(version.s3_version_key)
    render json: version_json(version).merge(content: content)
  end

  # POST /api/v1/vaults/:vault_id/files/:vault_file_id/versions/:id/restore
  def restore
    vault_file = find_vault_file
    version = vault_file.versions.find(params[:id])
    VaultVersioningService.new(vault: vault_file.vault).restore_version(vault_file, version)
    render json: { status: "restored", version_number: version.version_number }
  end

  private

  def find_vault_file
    vault = Current.workspace.vaults.find(params[:vault_id])
    vault.vault_files.find(params[:vault_file_id])
  end

  def version_json(v)
    {
      id: v.id,
      version_number: v.version_number,
      content_hash: v.content_hash,
      size_bytes: v.size_bytes,
      change_source: v.change_source,
      change_summary: v.change_summary,
      created_at: v.created_at.iso8601
    }
  end
end
```

### 6.2 Vault Snapshots

```ruby
# app/controllers/api/v1/vault_snapshots_controller.rb
# Lists, creates, and restores vault snapshots.
class Api::V1::VaultSnapshotsController < ApplicationController
  # GET /api/v1/vaults/:vault_id/snapshots
  def index
    vault = Current.workspace.vaults.find(params[:vault_id])
    snapshots = vault.snapshots.order(created_at: :desc).limit(30)
    render json: snapshots.map { |s| snapshot_json(s) }
  end

  # POST /api/v1/vaults/:vault_id/snapshots
  def create
    vault = Current.workspace.vaults.find(params[:vault_id])
    snapshot = VaultSnapshotService.new(vault: vault).create_snapshot(
      type: "manual",
      description: snapshot_params[:description]
    )
    render json: snapshot_json(snapshot), status: :created
  end

  # POST /api/v1/vaults/:vault_id/snapshots/:id/restore
  # Accepts optional `paths` array to restore only a subset of files.
  # If `paths` is omitted, restores the entire vault to the snapshot state.
  def restore
    vault = Current.workspace.vaults.find(params[:vault_id])
    snapshot = vault.snapshots.complete.find(params[:id])
    VaultSnapshotService.new(vault: vault).restore_snapshot(
      snapshot,
      paths: restore_params[:paths]
    )
    render json: { status: "restoring", snapshot_id: snapshot.id,
                   scope: restore_params[:paths].present? ? "selective" : "full" }
  end

  private

  def snapshot_params
    params.require(:snapshot).permit(:description)
  end

  def restore_params
    params.permit(paths: [])
  end

  def snapshot_json(s)
    {
      id: s.id,
      snapshot_type: s.snapshot_type,
      status: s.status,
      file_count: s.file_count,
      total_size_bytes: s.total_size_bytes,
      description: s.description,
      created_at: s.created_at.iso8601
    }
  end
end
```

### 6.3 Routes

```ruby
# config/routes.rb (add inside api/v1 namespace)
resources :vaults, only: [] do
  resources :snapshots, only: [:index, :create], controller: "vault_snapshots" do
    member do
      post :restore
    end
  end
  resources :files, only: [], param: :vault_file_id, controller: "vault_files" do
    resources :versions, only: [:index, :show], controller: "vault_file_versions" do
      member do
        post :restore
      end
    end
  end
end
```

---

## 7. Background Jobs

### 7.1 VaultSnapshotJob — Daily Automated Snapshots

```ruby
# app/jobs/vault_snapshot_job.rb
# Creates daily automated snapshots for all active vaults.
class VaultSnapshotJob < ApplicationJob
  queue_as :maintenance

  def perform
    Current.skip_workspace_scoping do
      Vault.active.find_each do |vault|
        VaultSnapshotService.new(vault: vault).create_snapshot(
          type: "automatic",
          description: "Daily automated snapshot — #{Date.current.iso8601}"
        )
      rescue => e
        Rails.logger.error "[VaultSnapshot] Failed for vault #{vault.id}: #{e.message}"
      end
    end
  end
end
```

### 7.2 VaultVersionCleanupJob — Retention Enforcement

```ruby
# app/jobs/vault_version_cleanup_job.rb
# Prunes old file versions beyond the retention policy.
class VaultVersionCleanupJob < ApplicationJob
  queue_as :maintenance

  RETENTION_DAYS = 30
  MAX_VERSIONS_PER_FILE = 100

  def perform
    Current.skip_workspace_scoping do
      prune_by_age
      prune_by_count
      prune_old_snapshots
    end
  end

  private

  # Delete versions older than retention period.
  def prune_by_age
    cutoff = RETENTION_DAYS.days.ago

    VaultFileVersion.where("created_at < ?", cutoff).find_each do |version|
      delete_version(version)
    end
  end

  # Cap versions per file to prevent unbounded growth.
  def prune_by_count
    VaultFile.find_each do |vf|
      excess_ids = vf.versions
                     .order(version_number: :desc)
                     .offset(MAX_VERSIONS_PER_FILE)
                     .pluck(:id)

      VaultFileVersion.where(id: excess_ids).find_each do |version|
        delete_version(version)
      end
    end
  end

  # Delete snapshots older than retention period.
  def prune_old_snapshots
    cutoff = RETENTION_DAYS.days.ago
    VaultSnapshot.where("created_at < ?", cutoff).where.not(snapshot_type: "pre_restore").find_each do |snapshot|
      begin
        s3 = VaultS3Service.new(snapshot.vault)
        s3.instance_variable_get(:@client).delete_object(
          bucket: Rails.application.config.x.vault_s3_bucket,
          key: snapshot.s3_manifest_key
        )
      rescue => e
        Rails.logger.warn "[VaultVersionCleanup] Failed to delete snapshot manifest #{snapshot.id}: #{e.message}"
      end
      snapshot.destroy!
    end
  end

  def delete_version(version)
    begin
      vault = version.vault_file.vault
      s3 = VaultS3Service.new(vault)
      s3.instance_variable_get(:@client).delete_object(
        bucket: Rails.application.config.x.vault_s3_bucket,
        key: version.s3_version_key
      )
    rescue => e
      Rails.logger.warn "[VaultVersionCleanup] Failed to delete version S3 object #{version.id}: #{e.message}"
    end
    version.destroy!
  end
end
```

### 7.3 GoodJob Cron Additions

```ruby
# Add to config/initializers/good_job.rb cron hash:
vault_daily_snapshot: {
  cron: "0 2 * * *",
  class: "VaultSnapshotJob",
  description: "Create daily snapshots for all active vaults"
},
vault_version_cleanup: {
  cron: "0 3 * * 0",
  class: "VaultVersionCleanupJob",
  description: "Prune vault file versions and snapshots beyond 30-day retention"
}
```

---

## 8. Backup Strategy

### 8.1 Data Layers and Their Backup

Vault data exists in three layers, each with its own backup mechanism:

| Layer | What | Backup Method | RPO |
|-------|------|---------------|-----|
| **PostgreSQL** | Vault metadata (vault_files, vault_chunks, vault_links, vault_file_versions, vault_snapshots) | `pg_dump -Fc` → restic → Hetzner S3 | 6 hours |
| **S3 (canonical files)** | Current vault files (SSE-C encrypted) | Already in S3 — is the backup. VaultS3SyncJob every 5 min. | ~5 minutes |
| **S3 (versions)** | Historical file versions (SSE-C encrypted) | Already in S3 — alongside canonical files. | Per change |
| **S3 (snapshots)** | Snapshot manifests (SSE-C encrypted) | Already in S3 — alongside canonical files. | Daily |
| **Local checkout** | Working copy of vault files | NOT backed up — ephemeral, reconstructable from S3. | N/A |

**Effective RPO for vault content**: ~5 minutes (VaultS3SyncJob frequency), not 24 hours. The 24-hour RPO from [PRD 06 SS8.5](../prd/06-deployment-hetzner.md) refers to the restic backup of workspace data to off-site storage. The S3 sync is the primary recovery path.

### 8.2 Disaster Recovery Scenarios

| Scenario | RPO | RTO | Recovery Path |
|----------|-----|-----|---------------|
| **Single file accidentally deleted** | 0 | < 1 min | Restore from version history via API |
| **Multiple files corrupted** | ≤ 24h | < 5 min | Restore from daily snapshot |
| **Local checkout lost** (disk failure) | 0 | Minutes | `VaultS3Service.checkout_to_local!` — pull from S3 |
| **S3 bucket corrupted** | ≤ 6h | < 2h | Restore PG from restic backup, reconstruct file list from metadata. Binary content from restic off-site backup. |
| **Full host loss** | ≤ 6h (PG) + 0 (S3) | < 2h | New host → restore PG from restic → checkout from S3 |
| **PG + S3 both lost** | ≤ 24h | < 4h | Restore from off-site restic (PG dump + S3 mirror) |

### 8.3 SSE-C Key Recovery

The encryption key dependency chain:

```
Rails master key (in 1Password + physical backup)
  → decrypts → vaults.encryption_key_enc (in PostgreSQL)
    → used as → SSE-C key for S3 operations
```

**If Rails master key is lost**: All vault data in S3 is permanently irrecoverable. The master key MUST be:

1. Stored in 1Password (`DailyWerk Production` vault)
2. Backed up as a physical copy (printed QR code in a safe, or hardware security key)
3. Included in the restic backup manifest (encrypted separately)
4. Documented in the `docs/infrastructure/secrets.md` runbook

**If PostgreSQL is lost but master key is available**: Restore PG from restic. The `encryption_key_enc` values are in the PG dump and will be decryptable with the master key.

**If a single vault's encryption key is corrupted**: The vault's S3 data is unrecoverable. No mitigation other than PG restore.

### 8.4 Alignment with PRD 06

| PRD 06 Backup | This RFC |
|---------------|----------|
| `pg_dump -Fc` into restic, every 6h | Covers vault_files, vault_chunks, vault_links, vault_file_versions, vault_snapshots |
| Workspace/vault data via restic, daily | S3 is the canonical store (5-min RPO), restic is secondary |
| Full server snapshot weekly | Covers everything |
| RTO < 15 min (app), < 2h (host rebuild) | Vault recovery aligns — checkout from S3 is minutes |

---

## 9. Version Retention Policy

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Max age | 30 days | Balance between recovery window and S3 cost |
| Max versions per file | 100 | Prevent unbounded growth from rapid-fire edits |
| Snapshot retention | 30 days | Matches version retention |
| Pre-restore snapshots | Kept indefinitely | Safety net for restore operations — manually cleaned |
| Content-hash dedup | Per file | Identical content not versioned twice |

**Future**: User-configurable retention via workspace plan settings. Premium plans could have 90-day or unlimited retention.

---

## 10. Configuration

### 10.1 Local Dev vs Production

| Aspect | Local Dev | Production |
|--------|-----------|------------|
| Version storage | RustFS (same bucket as files) | Hetzner S3 (same bucket, `versions/` prefix) |
| Snapshot storage | RustFS | Hetzner S3 (`snapshots/` prefix) |
| Automated snapshots | Same cron, can trigger manually | Daily at 2am |
| Version cleanup | Same cron | Weekly Sunday 3am |
| restic backup | Not configured in dev | Every 6h for PG, daily for workspace data |
| Restore testing | Via API/console | Via API + documented runbook |

---

## 11. Admin Metrics — Per-Workspace Storage Monitoring

Operators need visibility into storage costs and usage per workspace. This feeds into billing decisions (vault size limits, versioning as a paid feature) and capacity planning.

### 11.1 Metrics to Track

| Metric | Source | Granularity |
|--------|--------|-------------|
| Vault file count | `vault_files.count` | Per vault, per workspace |
| Vault current size (bytes) | `vaults.current_size_bytes` | Per vault |
| Version count | `vault_file_versions.count` | Per vault, per workspace |
| Version storage size (bytes) | `SUM(vault_file_versions.size_bytes)` | Per vault, per workspace |
| Snapshot count | `vault_snapshots.count` | Per vault |
| S3 object count + total size | S3 `ListObjectsV2` with prefix | Per vault (via cron job) |
| Embedding count | `vault_chunks.count WHERE embedding IS NOT NULL` | Per workspace |
| Estimated embedding cost | Chunk count × embedding price per token | Per workspace |

### 11.2 VaultMetricsJob — Periodic Aggregation

```ruby
# app/jobs/vault_metrics_job.rb
# Aggregates per-workspace vault storage metrics for the admin dashboard.
class VaultMetricsJob < ApplicationJob
  queue_as :maintenance

  def perform
    Current.skip_workspace_scoping do
      Workspace.find_each do |workspace|
        metrics = {
          total_vault_size_bytes: workspace.vaults.sum(:current_size_bytes),
          total_file_count: workspace.vaults.joins(:vault_files).count,
          total_version_count: VaultFileVersion.where(workspace: workspace).count,
          total_version_size_bytes: VaultFileVersion.where(workspace: workspace).sum(:size_bytes),
          total_chunk_count: VaultChunk.where(workspace: workspace).count,
          snapshot_count: VaultSnapshot.where(workspace: workspace).count,
          measured_at: Time.current
        }

        # Store as a Prometheus gauge (pushed via pushgateway or stored in DB for dashboard)
        Rails.logger.info "[VaultMetrics] workspace=#{workspace.id} #{metrics.to_json}"

        # Future: write to a vault_usage_metrics table for dashboard queries
      end
    end
  end
end
```

GoodJob cron:

```ruby
vault_metrics: {
  cron: "0 */4 * * *",
  class: "VaultMetricsJob",
  description: "Aggregate per-workspace vault storage metrics for admin monitoring"
}
```

### 11.3 Grafana Dashboard

The admin Grafana dashboard (accessible via Tailscale only, see [PRD 06 §10](../prd/06-deployment-hetzner.md)) should include a "Vault Storage" panel with:

- **Per-workspace table**: workspace name, vault count, total size, version size, file count
- **Top 10 workspaces by storage**: bar chart, helps identify outliers
- **Total platform storage**: sum across all workspaces, trend over time
- **Version storage ratio**: version bytes / current file bytes — if this grows unbounded, retention policy needs tuning
- **Alerts**: workspace exceeding 80% of vault size limit, total platform storage exceeding 70% of NVMe budget

---

## 12. Implementation Phases

### Phase 1: Schema + Models

1. Create `vault_file_versions` migration with RLS
2. Create `vault_snapshots` migration with RLS
3. Create VaultFileVersion and VaultSnapshot models
4. Add associations to VaultFile and Vault models
5. `bin/rails db:migrate`
6. **Verify**: Create a VaultFileVersion manually, RLS enforced

### Phase 2: Versioning Service

1. Create VaultVersioningService
2. Integrate version creation into VaultFileChangedJob (before overwrite)
3. Test version creation with content-hash dedup
4. **Verify**: Modify a file → version created → modify again with same content → no duplicate version

### Phase 3: Snapshot Service

1. Create VaultSnapshotService
2. Test snapshot creation (manifest written to S3)
3. Test snapshot restore (pre-restore snapshot created, files restored, re-indexed)
4. **Verify**: Create snapshot → modify files → restore → files match snapshot state

### Phase 4: API Endpoints

1. Create VaultFileVersionsController (index, show, restore)
2. Create VaultSnapshotsController (index, create, restore)
3. Add routes
4. **Verify**: API round-trip — list versions, view version content, restore version

### Phase 5: Background Jobs + Cron

1. Create VaultSnapshotJob (daily automated)
2. Create VaultVersionCleanupJob (weekly cleanup)
3. Add GoodJob cron entries
4. **Verify**: Snapshot job creates snapshots for all vaults, cleanup removes old versions

---

## 13. Known Limitations

| Limitation | Impact | Future Work |
|------------|--------|-------------|
| No diff view between versions | User can only see full content, not changes | Future: generate and cache unified diffs |
| No version annotations from agents | `change_summary` is rarely populated | Future: agent provides summary when writing |
| No cross-vault dedup | Same attachment in two vaults stored twice | Future: content-addressable storage layer |
| Orphaned S3 version objects | If DB cleanup fails, S3 objects accumulate | Future: S3 lifecycle rules or reconciliation job |
| Pre-restore snapshots never cleaned | Could accumulate | Manual cleanup via console, future: age-based policy |
| No user-configurable retention | All workspaces get 30 days | Future: workspace plan-based retention settings |

---

## 14. Verification Checklist

1. `bin/rails db:migrate` succeeds, both tables created with RLS
2. Modifying a vault file creates a version automatically (VaultFileChangedJob integration)
3. Identical content is not versioned twice (content-hash dedup)
4. Version restore writes content to local checkout, triggers re-indexing
5. `GET /api/v1/vaults/:id/files/:id/versions` returns version history
6. `POST /api/v1/vaults/:id/files/:id/versions/:id/restore` restores file
7. `POST /api/v1/vaults/:id/snapshots` creates a snapshot with manifest in S3
8. `POST /api/v1/vaults/:id/snapshots/:id/restore` restores vault to snapshot state
9. Pre-restore snapshot is automatically created before any restore
10. VaultVersionCleanupJob removes versions older than 30 days
11. VaultSnapshotJob creates daily snapshots for all active vaults
12. Workspace isolation: versions/snapshots with wrong `app.current_workspace_id` return no rows
13. GoodJob concurrency control prevents concurrent version creation for the same file
14. `bundle exec rails test` passes
15. `bundle exec rubocop` passes
16. `bundle exec brakeman --quiet` shows no critical issues
