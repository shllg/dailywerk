import type {
  Vault,
  VaultCreateInput,
  VaultFile,
  VaultFileResponse,
  VaultFilesResponse,
  VaultListResponse,
  VaultResponse,
  VaultSearchResponse,
  VaultSyncConfig,
  VaultSyncConfigInput,
} from '../types/vault'
import { apiRequest } from './api'

export async function fetchVaults(): Promise<Vault[]> {
  const response = await apiRequest<VaultListResponse>('/vaults')
  return response.vaults
}

export async function createVault(input: VaultCreateInput): Promise<Vault> {
  const response = await apiRequest<VaultResponse>('/vaults', {
    method: 'POST',
    body: JSON.stringify({ vault: input }),
  })
  return response.vault
}

export async function fetchVault(id: string): Promise<Vault & { recent_files: VaultFile[] }> {
  const response = await apiRequest<VaultResponse>(`/vaults/${id}`)
  return response.vault
}

export async function destroyVault(id: string): Promise<void> {
  await apiRequest<void>(`/vaults/${id}`, { method: 'DELETE' })
}

export async function fetchVaultFiles(
  vaultId: string,
  prefix?: string
): Promise<VaultFile[]> {
  const path = prefix
    ? `/vaults/${vaultId}/files?path=${encodeURIComponent(prefix)}`
    : `/vaults/${vaultId}/files`
  const response = await apiRequest<VaultFilesResponse>(path)
  return response.files
}

export async function fetchVaultFile(
  vaultId: string,
  fileId: string
): Promise<VaultFile & { content: string | null }> {
  const response = await apiRequest<VaultFileResponse>(`/vaults/${vaultId}/files/${fileId}`)
  return response.file
}

export async function searchVault(vaultId: string, query: string): Promise<VaultFile[]> {
  const response = await apiRequest<VaultSearchResponse>(
    `/vaults/${vaultId}/search?query=${encodeURIComponent(query)}`
  )
  return response.files
}

export async function updateSyncConfig(
  vaultId: string,
  input: VaultSyncConfigInput
): Promise<VaultSyncConfig> {
  const response = await apiRequest<{ sync_config: VaultSyncConfig }>(
    `/vaults/${vaultId}/sync_config`,
    {
      method: 'PUT',
      body: JSON.stringify({ sync_config: input }),
    }
  )
  return response.sync_config
}

export async function removeSyncConfig(vaultId: string): Promise<void> {
  await apiRequest<void>(`/vaults/${vaultId}/sync_config`, { method: 'DELETE' })
}

export async function setupSync(vaultId: string): Promise<{ message: string; sync_config: VaultSyncConfig }> {
  return apiRequest<{ message: string; sync_config: VaultSyncConfig }>(
    `/vaults/${vaultId}/sync_config/setup`,
    { method: 'POST' }
  )
}

export async function startSync(vaultId: string): Promise<{ message: string; sync_config: VaultSyncConfig }> {
  return apiRequest<{ message: string; sync_config: VaultSyncConfig }>(
    `/vaults/${vaultId}/sync_config/start`,
    { method: 'POST' }
  )
}

export async function stopSync(vaultId: string): Promise<{ message: string; sync_config: VaultSyncConfig }> {
  return apiRequest<{ message: string; sync_config: VaultSyncConfig }>(
    `/vaults/${vaultId}/sync_config/stop`,
    { method: 'POST' }
  )
}
