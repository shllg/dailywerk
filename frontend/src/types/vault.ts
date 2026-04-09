export interface Vault {
  id: string
  name: string
  slug: string
  vault_type: 'native' | 'obsidian'
  status: 'active' | 'syncing' | 'error' | 'suspended'
  file_count: number
  current_size_bytes: number
  max_size_bytes: number
  created_at: string
  updated_at: string
  sync_config?: VaultSyncConfig
}

export interface VaultFile {
  id: string
  path: string
  file_type: string
  title: string | null
  content_hash: string | null
  size_bytes: number | null
  tags: string[]
  updated_at: string
}

export interface VaultFileWithContent extends VaultFile {
  content: string | null
  content_type?: string | null
}

export interface VaultSyncConfig {
  sync_type: 'obsidian' | 'none'
  sync_mode: 'bidirectional' | 'pull_only' | 'mirror_remote'
  obsidian_vault_name: string | null
  device_name: string
  process_status: 'stopped' | 'starting' | 'running' | 'error' | 'crashed'
  last_sync_at: string | null
  error_message: string | null
  has_email: boolean
  has_password: boolean
  has_encryption_password: boolean
}

export interface VaultListResponse {
  vaults: Vault[]
}

export interface VaultResponse {
  vault: Vault & {
    recent_files: VaultFile[]
  }
}

export interface VaultFilesResponse {
  files: VaultFile[]
}

export interface VaultFileResponse {
  file: VaultFileWithContent
}

export interface VaultSearchResponse {
  query: string
  files: VaultFile[]
}

export interface VaultCreateInput {
  name: string
  vault_type: 'native' | 'obsidian'
}

export interface VaultSyncConfigInput {
  sync_type: 'obsidian' | 'none'
  sync_mode: 'bidirectional' | 'pull_only' | 'mirror_remote'
  obsidian_vault_name: string
  device_name: string
  obsidian_email?: string
  obsidian_password?: string
  obsidian_encryption_password?: string
}
