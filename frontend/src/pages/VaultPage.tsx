import { useEffect, useState } from 'react'
import type { Vault, VaultFile, VaultSyncConfig } from '../types/vault'
import {
  createVault,
  destroyVault,
  fetchVault,
  fetchVaultFile,
  fetchVaultFiles,
  fetchVaults,
  removeSyncConfig,
  searchVault,
  setupSync,
  startSync,
  stopSync,
  updateSyncConfig,
} from '../services/vaultApi'

type Tab = 'files' | 'search' | 'sync'

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${parseFloat((bytes / k ** i).toFixed(1))} ${sizes[i]}`
}

function formatDate(value: string | null): string {
  if (!value) return 'Never'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat([], {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date)
}

function getStatusColor(status: string): string {
  switch (status) {
    case 'active':
    case 'running':
      return 'text-emerald-400'
    case 'syncing':
    case 'starting':
      return 'text-amber-400'
    case 'error':
    case 'crashed':
      return 'text-rose-400'
    case 'stopped':
      return 'text-slate-400'
    case 'suspended':
      return 'text-orange-400'
    default:
      return 'text-slate-400'
  }
}

function getStatusBg(status: string): string {
  switch (status) {
    case 'active':
    case 'running':
      return 'bg-emerald-500/10 border-emerald-500/20'
    case 'syncing':
    case 'starting':
      return 'bg-amber-500/10 border-amber-500/20'
    case 'error':
    case 'crashed':
      return 'bg-rose-500/10 border-rose-500/20'
    case 'stopped':
      return 'bg-slate-500/10 border-slate-500/20'
    case 'suspended':
      return 'bg-orange-500/10 border-orange-500/20'
    default:
      return 'bg-slate-500/10 border-slate-500/20'
  }
}

function getFileTypeIcon(fileType: string): string {
  switch (fileType) {
    case 'markdown':
      return '📝'
    case 'canvas':
      return '🎨'
    case 'image':
      return '🖼️'
    case 'pdf':
      return '📄'
    case 'audio':
      return '🎵'
    case 'video':
      return '🎬'
    default:
      return '📃'
  }
}

export function VaultPage() {
  // Vault list state
  const [vaults, setVaults] = useState<Vault[]>([])
  const [isLoadingVaults, setIsLoadingVaults] = useState(true)
  const [vaultError, setVaultError] = useState<string | null>(null)

  // Selected vault state
  const [selectedVaultId, setSelectedVaultId] = useState<string | null>(null)
  const [selectedVault, setSelectedVault] = useState<Vault | null>(null)
  const [isLoadingVault, setIsLoadingVault] = useState(false)

  // Create vault form state
  const [showCreateForm, setShowCreateForm] = useState(false)
  const [newVaultName, setNewVaultName] = useState('')
  const [newVaultType, setNewVaultType] = useState<'native' | 'obsidian'>('native')
  const [isCreating, setIsCreating] = useState(false)

  // Tab state
  const [activeTab, setActiveTab] = useState<Tab>('files')

  // Files tab state
  const [files, setFiles] = useState<VaultFile[]>([])
  const [isLoadingFiles, setIsLoadingFiles] = useState(false)
  const [selectedFile, setSelectedFile] = useState<VaultFile | null>(null)
  const [fileContent, setFileContent] = useState<string | null>(null)
  const [isLoadingFile, setIsLoadingFile] = useState(false)

  // Search tab state
  const [searchQuery, setSearchQuery] = useState('')
  const [searchResults, setSearchResults] = useState<VaultFile[]>([])
  const [isSearching, setIsSearching] = useState(false)
  const [hasSearched, setHasSearched] = useState(false)

  // Sync tab state
  const [syncForm, setSyncForm] = useState<{
    obsidian_email: string
    obsidian_password: string
    obsidian_encryption_password: string
    obsidian_vault_name: string
    device_name: string
    sync_mode: 'bidirectional' | 'pull_only' | 'mirror_remote'
  }>({
    obsidian_email: '',
    obsidian_password: '',
    obsidian_encryption_password: '',
    obsidian_vault_name: '',
    device_name: '',
    sync_mode: 'bidirectional',
  })
  const [mfaCode, setMfaCode] = useState('')
  const [isSavingSync, setIsSavingSync] = useState(false)
  const [isSyncActionPending, setIsSyncActionPending] = useState(false)

  // Load vaults on mount
  useEffect(() => {
    loadVaults()
  }, [])

  // Load selected vault details
  useEffect(() => {
    if (selectedVaultId) {
      loadVault(selectedVaultId)
    } else {
      setSelectedVault(null)
      setFiles([])
      setSelectedFile(null)
      setFileContent(null)
    }
  }, [selectedVaultId])

  // Load files when tab changes to files
  useEffect(() => {
    if (selectedVaultId && activeTab === 'files') {
      loadFiles(selectedVaultId)
    }
  }, [selectedVaultId, activeTab])

  // Sync form initialization from vault
  useEffect(() => {
    if (selectedVault?.sync_config) {
      const config = selectedVault.sync_config
      setSyncForm({
        obsidian_email: '',
        obsidian_password: '',
        obsidian_encryption_password: '',
        obsidian_vault_name: config.obsidian_vault_name || '',
        device_name: config.device_name || '',
        sync_mode: config.sync_mode || 'bidirectional',
      })
    } else {
      setSyncForm({
        obsidian_email: '',
        obsidian_password: '',
        obsidian_encryption_password: '',
        obsidian_vault_name: '',
        device_name: '',
        sync_mode: 'bidirectional',
      })
    }
  }, [selectedVault?.sync_config])

  async function loadVaults() {
    setIsLoadingVaults(true)
    setVaultError(null)
    try {
      const data = await fetchVaults()
      setVaults(data)
    } catch (err) {
      setVaultError(err instanceof Error ? err.message : 'Failed to load vaults')
    } finally {
      setIsLoadingVaults(false)
    }
  }

  async function loadVault(id: string) {
    setIsLoadingVault(true)
    try {
      const data = await fetchVault(id)
      setSelectedVault(data)
    } catch (err) {
      setVaultError(err instanceof Error ? err.message : 'Failed to load vault')
    } finally {
      setIsLoadingVault(false)
    }
  }

  async function loadFiles(vaultId: string) {
    setIsLoadingFiles(true)
    try {
      const data = await fetchVaultFiles(vaultId)
      setFiles(data)
    } catch {
      // Silent fail - files are optional
    } finally {
      setIsLoadingFiles(false)
    }
  }

  async function handleCreateVault(e: React.FormEvent) {
    e.preventDefault()
    if (!newVaultName.trim()) return

    setIsCreating(true)
    try {
      const vault = await createVault({
        name: newVaultName.trim(),
        vault_type: newVaultType,
      })
      setVaults((prev) => [vault, ...prev])
      setSelectedVaultId(vault.id)
      setShowCreateForm(false)
      setNewVaultName('')
      setNewVaultType('native')
    } catch (err) {
      setVaultError(err instanceof Error ? err.message : 'Failed to create vault')
    } finally {
      setIsCreating(false)
    }
  }

  async function handleDeleteVault(vaultId: string) {
    if (!window.confirm('Are you sure you want to delete this vault? This action cannot be undone.')) {
      return
    }

    try {
      await destroyVault(vaultId)
      setVaults((prev) => prev.filter((v) => v.id !== vaultId))
      if (selectedVaultId === vaultId) {
        setSelectedVaultId(null)
      }
    } catch (err) {
      setVaultError(err instanceof Error ? err.message : 'Failed to delete vault')
    }
  }

  async function handleSelectFile(file: VaultFile) {
    if (!selectedVaultId) return
    setSelectedFile(file)
    setIsLoadingFile(true)
    try {
      const data = await fetchVaultFile(selectedVaultId, file.id)
      setFileContent(data.content)
    } catch {
      setFileContent(null)
    } finally {
      setIsLoadingFile(false)
    }
  }

  async function handleSearch(e: React.FormEvent) {
    e.preventDefault()
    if (!selectedVaultId || !searchQuery.trim()) return

    setIsSearching(true)
    setHasSearched(true)
    try {
      const results = await searchVault(selectedVaultId, searchQuery.trim())
      setSearchResults(results)
    } catch {
      setSearchResults([])
    } finally {
      setIsSearching(false)
    }
  }

  async function handleSaveSyncConfig(e: React.FormEvent) {
    e.preventDefault()
    if (!selectedVaultId) return

    setIsSavingSync(true)
    try {
      const config = await updateSyncConfig(selectedVaultId, {
        sync_type: 'obsidian',
        sync_mode: syncForm.sync_mode,
        obsidian_vault_name: syncForm.obsidian_vault_name,
        device_name: syncForm.device_name,
        obsidian_email: syncForm.obsidian_email || undefined,
        obsidian_password: syncForm.obsidian_password || undefined,
        obsidian_encryption_password: syncForm.obsidian_encryption_password || undefined,
      })
      // Update local state
      setSelectedVault((prev) =>
        prev ? { ...prev, sync_config: config } : null
      )
      // Clear passwords after save (they're one-way encrypted)
      setSyncForm((prev) => ({
        ...prev,
        obsidian_email: '',
        obsidian_password: '',
        obsidian_encryption_password: '',
      }))
    } catch (err) {
      setVaultError(err instanceof Error ? err.message : 'Failed to save sync config')
    } finally {
      setIsSavingSync(false)
    }
  }

  async function handleRemoveSyncConfig() {
    if (!selectedVaultId) return
    if (!window.confirm('Remove Obsidian sync configuration?')) return

    try {
      await removeSyncConfig(selectedVaultId)
      setSelectedVault((prev) => (prev ? { ...prev, sync_config: undefined } : null))
    } catch (err) {
      setVaultError(err instanceof Error ? err.message : 'Failed to remove sync config')
    }
  }

  async function handleSyncAction(action: 'setup' | 'start' | 'stop') {
    if (!selectedVaultId) return

    setIsSyncActionPending(true)
    try {
      let result: { sync_config: VaultSyncConfig }
      switch (action) {
        case 'setup':
          result = await setupSync(selectedVaultId, mfaCode || undefined)
          setMfaCode('')
          break
        case 'start':
          result = await startSync(selectedVaultId)
          break
        case 'stop':
          result = await stopSync(selectedVaultId)
          break
      }
      setSelectedVault((prev) =>
        prev ? { ...prev, sync_config: result.sync_config } : null
      )
    } catch (err) {
      setVaultError(err instanceof Error ? err.message : `Failed to ${action} sync`)
    } finally {
      setIsSyncActionPending(false)
    }
  }

  const vaultListSection = (
    <section className="flex flex-col gap-4 overflow-hidden">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-slate-50">Vaults</h2>
        <button
          onClick={() => setShowCreateForm(true)}
          className="rounded-lg bg-cyan-500/20 px-3 py-1.5 text-sm font-medium text-cyan-300 hover:bg-cyan-500/30"
        >
          + Create
        </button>
      </div>

      {showCreateForm && (
        <form
          onSubmit={handleCreateVault}
          className="rounded-xl border border-white/10 bg-white/[0.03] p-4"
        >
          <div className="flex flex-col gap-3">
            <input
              type="text"
              placeholder="Vault name"
              value={newVaultName}
              onChange={(e) => setNewVaultName(e.target.value)}
              className="rounded-lg border border-white/10 bg-white/[0.05] px-3 py-2 text-sm text-slate-200 placeholder:text-slate-500 focus:border-cyan-500/50 focus:outline-none"
            />
            <div className="flex gap-2">
              <button
                type="button"
                onClick={() => setNewVaultType('native')}
                className={`rounded-lg px-3 py-2 text-sm ${
                  newVaultType === 'native'
                    ? 'bg-cyan-500/20 text-cyan-300'
                    : 'bg-white/[0.05] text-slate-400 hover:bg-white/[0.08]'
                }`}
              >
                Native
              </button>
              <button
                type="button"
                onClick={() => setNewVaultType('obsidian')}
                className={`rounded-lg px-3 py-2 text-sm ${
                  newVaultType === 'obsidian'
                    ? 'bg-cyan-500/20 text-cyan-300'
                    : 'bg-white/[0.05] text-slate-400 hover:bg-white/[0.08]'
                }`}
              >
                Obsidian
              </button>
            </div>
            <div className="flex gap-2">
              <button
                type="submit"
                disabled={isCreating || !newVaultName.trim()}
                className="rounded-lg bg-cyan-500/20 px-3 py-1.5 text-sm font-medium text-cyan-300 hover:bg-cyan-500/30 disabled:opacity-50"
              >
                {isCreating ? 'Creating...' : 'Create'}
              </button>
              <button
                type="button"
                onClick={() => {
                  setShowCreateForm(false)
                  setNewVaultName('')
                }}
                className="rounded-lg bg-white/[0.05] px-3 py-1.5 text-sm text-slate-400 hover:bg-white/[0.08]"
              >
                Cancel
              </button>
            </div>
          </div>
        </form>
      )}

      <div className="flex flex-col gap-2 overflow-auto">
        {isLoadingVaults ? (
          <p className="text-sm text-slate-500">Loading vaults...</p>
        ) : vaults.length === 0 ? (
          <p className="text-sm text-slate-500">No vaults yet. Create one to get started.</p>
        ) : (
          vaults.map((vault) => (
            <button
              key={vault.id}
              onClick={() => setSelectedVaultId(vault.id)}
              className={`flex flex-col items-start rounded-xl border p-3 text-left transition-colors ${
                selectedVaultId === vault.id
                  ? 'border-cyan-500/30 bg-cyan-500/10'
                  : 'border-white/10 bg-white/[0.03] hover:bg-white/[0.05]'
              }`}
            >
              <div className="flex w-full items-center justify-between">
                <span className="font-medium text-slate-200">{vault.name}</span>
                <span
                  className={`text-[10px] uppercase ${
                    vault.vault_type === 'obsidian' ? 'text-purple-400' : 'text-emerald-400'
                  }`}
                >
                  {vault.vault_type}
                </span>
              </div>
              <div className="mt-1 flex items-center gap-3 text-xs text-slate-500">
                <span>{vault.file_count} files</span>
                <span>{formatBytes(vault.current_size_bytes)}</span>
              </div>
              {vault.sync_config && (
                <div className="mt-2 flex items-center gap-1.5">
                  <span
                    className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-medium ${getStatusBg(
                      vault.sync_config.process_status
                    )} ${getStatusColor(vault.sync_config.process_status)}`}
                  >
                    {vault.sync_config.process_status}
                  </span>
                  {vault.sync_config.process_status === 'running' && (
                    <span className="text-[10px] text-slate-500">synced</span>
                  )}
                </div>
              )}
            </button>
          ))
        )}
      </div>
    </section>
  )

  const vaultDetailSection = selectedVault ? (
    <div className="flex flex-col gap-4">
      {/* Vault Header */}
      <div className="flex items-start justify-between">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-slate-50">{selectedVault.name}</h1>
            <span
              className={`rounded-full px-2 py-0.5 text-[10px] uppercase ${
                selectedVault.vault_type === 'obsidian'
                  ? 'bg-purple-500/10 text-purple-400'
                  : 'bg-emerald-500/10 text-emerald-400'
              }`}
            >
              {selectedVault.vault_type}
            </span>
          </div>
          <div className="mt-1 flex items-center gap-4 text-sm text-slate-400">
            <span>{selectedVault.file_count} files</span>
            <span>{formatBytes(selectedVault.current_size_bytes)}</span>
            <span>Updated {formatDate(selectedVault.updated_at)}</span>
          </div>
        </div>
        <button
          onClick={() => handleDeleteVault(selectedVault.id)}
          className="rounded-lg bg-rose-500/10 px-3 py-1.5 text-sm text-rose-400 hover:bg-rose-500/20"
        >
          Delete
        </button>
      </div>

      {/* Tabs */}
      <div className="flex gap-1 rounded-lg border border-white/10 bg-white/[0.03] p-1">
        <button
          onClick={() => setActiveTab('files')}
          className={`rounded-md px-4 py-2 text-sm font-medium transition-colors ${
            activeTab === 'files'
              ? 'bg-white/[0.08] text-slate-200'
              : 'text-slate-400 hover:text-slate-300'
          }`}
        >
          Files
        </button>
        <button
          onClick={() => setActiveTab('search')}
          className={`rounded-md px-4 py-2 text-sm font-medium transition-colors ${
            activeTab === 'search'
              ? 'bg-white/[0.08] text-slate-200'
              : 'text-slate-400 hover:text-slate-300'
          }`}
        >
          Search
        </button>
        {selectedVault.vault_type === 'obsidian' && (
          <button
            onClick={() => setActiveTab('sync')}
            className={`rounded-md px-4 py-2 text-sm font-medium transition-colors ${
              activeTab === 'sync'
                ? 'bg-white/[0.08] text-slate-200'
                : 'text-slate-400 hover:text-slate-300'
            }`}
          >
            Sync
          </button>
        )}
      </div>

      {/* Tab Content */}
      <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
        {activeTab === 'files' && (
          <div className="flex flex-1 gap-4 overflow-hidden">
            {/* File List */}
            <div className="flex w-1/2 flex-col gap-2 overflow-auto rounded-xl border border-white/10 bg-white/[0.03] p-3">
              {isLoadingFiles ? (
                <p className="text-sm text-slate-500">Loading files...</p>
              ) : files.length === 0 ? (
                <p className="text-sm text-slate-500">No files in this vault yet.</p>
              ) : (
                files.map((file) => (
                  <button
                    key={file.id}
                    onClick={() => handleSelectFile(file)}
                    className={`flex items-center gap-3 rounded-lg border p-2 text-left transition-colors ${
                      selectedFile?.id === file.id
                        ? 'border-cyan-500/30 bg-cyan-500/10'
                        : 'border-white/5 bg-white/[0.03] hover:bg-white/[0.05]'
                    }`}
                  >
                    <span className="text-lg">{getFileTypeIcon(file.file_type)}</span>
                    <div className="flex-1 min-w-0">
                      <p className="truncate text-sm font-medium text-slate-200">
                        {file.title || file.path}
                      </p>
                      <p className="text-xs text-slate-500">{file.path}</p>
                    </div>
                    <span className="text-xs text-slate-500">
                      {formatBytes(file.size_bytes || 0)}
                    </span>
                  </button>
                ))
              )}
            </div>

            {/* File Content */}
            <div className="flex w-1/2 flex-col rounded-xl border border-white/10 bg-white/[0.03] p-4">
              {selectedFile ? (
                <>
                  <div className="mb-3 flex items-center justify-between">
                    <div>
                      <h3 className="font-medium text-slate-200">
                        {selectedFile.title || selectedFile.path}
                      </h3>
                      <p className="text-xs text-slate-500">{selectedFile.path}</p>
                    </div>
                    <span className="rounded-full bg-white/[0.05] px-2 py-1 text-xs text-slate-400">
                      {selectedFile.file_type}
                    </span>
                  </div>
                  {isLoadingFile ? (
                    <p className="text-sm text-slate-500">Loading content...</p>
                  ) : fileContent === null ? (
                    <p className="text-sm text-slate-500">
                      Binary file - content not available
                    </p>
                  ) : (
                    <pre className="flex-1 overflow-auto rounded-lg bg-black/30 p-3 text-xs text-slate-300">
                      {fileContent}
                    </pre>
                  )}
                </>
              ) : (
                <p className="text-sm text-slate-500">Select a file to view its content</p>
              )}
            </div>
          </div>
        )}

        {activeTab === 'search' && (
          <div className="flex flex-col gap-4 overflow-hidden">
            <form onSubmit={handleSearch} className="flex gap-2">
              <input
                type="text"
                placeholder="Search files by content..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                className="flex-1 rounded-lg border border-white/10 bg-white/[0.05] px-4 py-2 text-sm text-slate-200 placeholder:text-slate-500 focus:border-cyan-500/50 focus:outline-none"
              />
              <button
                type="submit"
                disabled={isSearching || !searchQuery.trim()}
                className="rounded-lg bg-cyan-500/20 px-4 py-2 text-sm font-medium text-cyan-300 hover:bg-cyan-500/30 disabled:opacity-50"
              >
                {isSearching ? 'Searching...' : 'Search'}
              </button>
            </form>

            {hasSearched && (
              <div className="flex flex-1 flex-col gap-2 overflow-auto rounded-xl border border-white/10 bg-white/[0.03] p-3">
                {searchResults.length === 0 ? (
                  <p className="text-sm text-slate-500">No results found.</p>
                ) : (
                  searchResults.map((file) => (
                    <button
                      key={file.id}
                      onClick={() => {
                        handleSelectFile(file)
                        setActiveTab('files')
                      }}
                      className="flex items-center gap-3 rounded-lg border border-white/5 bg-white/[0.03] p-2 text-left transition-colors hover:bg-white/[0.05]"
                    >
                      <span className="text-lg">{getFileTypeIcon(file.file_type)}</span>
                      <div className="flex-1 min-w-0">
                        <p className="truncate text-sm font-medium text-slate-200">
                          {file.title || file.path}
                        </p>
                        <p className="text-xs text-slate-500">{file.path}</p>
                      </div>
                    </button>
                  ))
                )}
              </div>
            )}
          </div>
        )}

        {activeTab === 'sync' && selectedVault.vault_type === 'obsidian' && (
          <div className="flex flex-col gap-6 overflow-auto rounded-xl border border-white/10 bg-white/[0.03] p-4">
            {/* Sync Status */}
            {selectedVault.sync_config && (
              <div className="rounded-lg border border-white/10 bg-white/[0.05] p-4">
                <h3 className="mb-3 font-medium text-slate-200">Sync Status</h3>
                <div className="grid grid-cols-2 gap-4 text-sm">
                  <div>
                    <p className="text-slate-500">Status</p>
                    <span
                      className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${getStatusBg(
                        selectedVault.sync_config.process_status
                      )} ${getStatusColor(selectedVault.sync_config.process_status)}`}
                    >
                      {selectedVault.sync_config.process_status}
                    </span>
                  </div>
                  <div>
                    <p className="text-slate-500">Mode</p>
                    <p className="text-slate-300">{selectedVault.sync_config.sync_mode}</p>
                  </div>
                  <div>
                    <p className="text-slate-500">Vault Name</p>
                    <p className="text-slate-300">
                      {selectedVault.sync_config.obsidian_vault_name || 'Not configured'}
                    </p>
                  </div>
                  <div>
                    <p className="text-slate-500">Last Sync</p>
                    <p className="text-slate-300">
                      {formatDate(selectedVault.sync_config.last_sync_at)}
                    </p>
                  </div>
                  {selectedVault.sync_config.error_message && (
                    <div className="col-span-2">
                      <p className="text-rose-400">{selectedVault.sync_config.error_message}</p>
                    </div>
                  )}
                </div>

                <div className="mt-4 flex items-end gap-2">
                  <div className="flex items-end gap-2">
                    <div>
                      <label className="mb-1 block text-xs text-slate-500">
                        2FA Code (if enabled)
                      </label>
                      <input
                        type="text"
                        inputMode="numeric"
                        autoComplete="one-time-code"
                        maxLength={6}
                        value={mfaCode}
                        onChange={(e) => setMfaCode(e.target.value.replace(/\D/g, ''))}
                        placeholder="123456"
                        className="w-24 rounded-lg border border-white/10 bg-white/[0.05] px-3 py-1.5 text-sm text-slate-200 placeholder:text-slate-500 focus:border-cyan-500/50 focus:outline-none"
                      />
                    </div>
                    <button
                      onClick={() => handleSyncAction('setup')}
                      disabled={isSyncActionPending}
                      className="rounded-lg bg-cyan-500/20 px-3 py-1.5 text-sm font-medium text-cyan-300 hover:bg-cyan-500/30 disabled:opacity-50"
                    >
                      Setup
                    </button>
                  </div>
                  <button
                    onClick={() => handleSyncAction('start')}
                    disabled={isSyncActionPending}
                    className="rounded-lg bg-emerald-500/20 px-3 py-1.5 text-sm font-medium text-emerald-300 hover:bg-emerald-500/30 disabled:opacity-50"
                  >
                    Start
                  </button>
                  <button
                    onClick={() => handleSyncAction('stop')}
                    disabled={isSyncActionPending}
                    className="rounded-lg bg-rose-500/20 px-3 py-1.5 text-sm font-medium text-rose-300 hover:bg-rose-500/30 disabled:opacity-50"
                  >
                    Stop
                  </button>
                </div>
              </div>
            )}

            {/* Sync Configuration Form */}
            <form onSubmit={handleSaveSyncConfig} className="flex flex-col gap-4">
              <h3 className="font-medium text-slate-200">Sync Configuration</h3>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="mb-1 block text-xs text-slate-500">Device Name</label>
                  <input
                    type="text"
                    value={syncForm.device_name}
                    onChange={(e) =>
                      setSyncForm((prev) => ({ ...prev, device_name: e.target.value }))
                    }
                    placeholder="My Laptop"
                    className="w-full rounded-lg border border-white/10 bg-white/[0.05] px-3 py-2 text-sm text-slate-200 placeholder:text-slate-500 focus:border-cyan-500/50 focus:outline-none"
                  />
                </div>
                <div>
                  <label className="mb-1 block text-xs text-slate-500">Obsidian Vault Name</label>
                  <input
                    type="text"
                    value={syncForm.obsidian_vault_name}
                    onChange={(e) =>
                      setSyncForm((prev) => ({ ...prev, obsidian_vault_name: e.target.value }))
                    }
                    placeholder="My Second Brain"
                    className="w-full rounded-lg border border-white/10 bg-white/[0.05] px-3 py-2 text-sm text-slate-200 placeholder:text-slate-500 focus:border-cyan-500/50 focus:outline-none"
                  />
                </div>
              </div>

              <div>
                <label className="mb-1 block text-xs text-slate-500">Sync Mode</label>
                <div className="flex gap-2">
                  {(['bidirectional', 'pull_only', 'mirror_remote'] as const).map((mode) => (
                    <button
                      key={mode}
                      type="button"
                      onClick={() => setSyncForm((prev) => ({ ...prev, sync_mode: mode }))}
                      className={`rounded-lg px-3 py-2 text-sm ${
                        syncForm.sync_mode === mode
                          ? 'bg-cyan-500/20 text-cyan-300'
                          : 'bg-white/[0.05] text-slate-400 hover:bg-white/[0.08]'
                      }`}
                    >
                      {mode.replace('_', ' ')}
                    </button>
                  ))}
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="mb-1 block text-xs text-slate-500">
                    Obsidian Email
                    {selectedVault.sync_config?.has_email && (
                      <span className="ml-2 text-emerald-400">✓ configured</span>
                    )}
                  </label>
                  <input
                    type="email"
                    value={syncForm.obsidian_email}
                    onChange={(e) =>
                      setSyncForm((prev) => ({ ...prev, obsidian_email: e.target.value }))
                    }
                    placeholder="user@example.com"
                    className="w-full rounded-lg border border-white/10 bg-white/[0.05] px-3 py-2 text-sm text-slate-200 placeholder:text-slate-500 focus:border-cyan-500/50 focus:outline-none"
                  />
                </div>
                <div>
                  <label className="mb-1 block text-xs text-slate-500">
                    Obsidian Password
                    {selectedVault.sync_config?.has_password && (
                      <span className="ml-2 text-emerald-400">✓ configured</span>
                    )}
                  </label>
                  <input
                    type="password"
                    value={syncForm.obsidian_password}
                    onChange={(e) =>
                      setSyncForm((prev) => ({ ...prev, obsidian_password: e.target.value }))
                    }
                    placeholder="••••••••"
                    className="w-full rounded-lg border border-white/10 bg-white/[0.05] px-3 py-2 text-sm text-slate-200 placeholder:text-slate-500 focus:border-cyan-500/50 focus:outline-none"
                  />
                </div>
              </div>

              <div>
                <label className="mb-1 block text-xs text-slate-500">
                  Encryption Password (optional)
                  {selectedVault.sync_config?.has_encryption_password && (
                    <span className="ml-2 text-emerald-400">✓ configured</span>
                  )}
                </label>
                <input
                  type="password"
                  value={syncForm.obsidian_encryption_password}
                  onChange={(e) =>
                    setSyncForm((prev) => ({
                      ...prev,
                      obsidian_encryption_password: e.target.value,
                    }))
                  }
                  placeholder="••••••••"
                  className="w-full rounded-lg border border-white/10 bg-white/[0.05] px-3 py-2 text-sm text-slate-200 placeholder:text-slate-500 focus:border-cyan-500/50 focus:outline-none"
                />
              </div>

              <div className="flex gap-2">
                <button
                  type="submit"
                  disabled={isSavingSync}
                  className="rounded-lg bg-cyan-500/20 px-4 py-2 text-sm font-medium text-cyan-300 hover:bg-cyan-500/30 disabled:opacity-50"
                >
                  {isSavingSync ? 'Saving...' : 'Save Configuration'}
                </button>
                {selectedVault.sync_config && (
                  <button
                    type="button"
                    onClick={handleRemoveSyncConfig}
                    className="rounded-lg bg-rose-500/10 px-4 py-2 text-sm text-rose-400 hover:bg-rose-500/20"
                  >
                    Remove Config
                  </button>
                )}
              </div>
            </form>
          </div>
        )}
      </div>
    </div>
  ) : null

  return (
    <div className="flex min-h-0 flex-1 gap-6 p-6">
      {/* Sidebar */}
      <aside className="flex w-64 flex-col gap-4 overflow-hidden">
        {vaultListSection}
      </aside>

      {/* Main Content */}
      <main className="flex min-h-0 flex-1 flex-col overflow-hidden rounded-[32px] border border-white/10 bg-[linear-gradient(135deg,rgba(8,15,30,0.92),rgba(15,23,42,0.86))] p-6 shadow-[0_24px_90px_rgba(2,6,23,0.35)]">
        {vaultError && (
          <div className="mb-4 rounded-lg bg-rose-500/10 p-3 text-sm text-rose-400">
            {vaultError}
          </div>
        )}

        {isLoadingVault ? (
          <p className="text-slate-500">Loading vault...</p>
        ) : selectedVault ? (
          vaultDetailSection
        ) : (
          <div className="flex flex-1 flex-col items-center justify-center gap-4 text-center">
            <p className="text-lg text-slate-400">Select a vault to view its contents</p>
            <p className="text-sm text-slate-500">
              Vaults are workspaces for organizing files that agents can read and write.
            </p>
          </div>
        )}
      </main>
    </div>
  )
}
