import { startTransition, useDeferredValue, useEffect, useMemo, useState } from 'react'
import {
  createMemoryEntry,
  deactivateMemoryEntry,
  fetchMemoryEntries,
  updateMemoryEntry,
} from '../services/memoryApi'
import type { MemoryAgentScope, MemoryEntry, MemoryMutationInput } from '../types/memory'

type ScopeFilter = 'all' | 'shared' | 'private'
type StatusFilter = 'active' | 'inactive' | 'all'

interface MemoryFormState {
  agentId: string
  category: string
  confidence: string
  content: string
  importance: string
  reason: string
  visibility: 'shared' | 'private'
}

function formatRelativeDate(value: string | null) {
  if (!value) {
    return 'Never'
  }

  const date = new Date(value)
  if (Number.isNaN(date.getTime())) {
    return value
  }

  return new Intl.DateTimeFormat([], {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date)
}

function buildInitialForm(categories: string[], agents: MemoryAgentScope[]): MemoryFormState {
  return {
    agentId: agents[0]?.id ?? '',
    category: categories[0] ?? 'fact',
    confidence: '0.70',
    content: '',
    importance: '5',
    reason: '',
    visibility: 'shared',
  }
}

function formFromEntry(entry: MemoryEntry): MemoryFormState {
  return {
    agentId: entry.agent?.id ?? '',
    category: entry.category,
    confidence: entry.confidence.toFixed(2),
    content: entry.content,
    importance: String(entry.importance),
    reason: '',
    visibility: entry.visibility,
  }
}

function buildPayload(form: MemoryFormState): MemoryMutationInput {
  return {
    agent_id: form.visibility === 'private' ? form.agentId : null,
    category: form.category,
    confidence: Number(form.confidence),
    content: form.content,
    importance: Number(form.importance),
    reason: form.reason || undefined,
    visibility: form.visibility,
  }
}

export function MemoryPage() {
  const [entries, setEntries] = useState<MemoryEntry[]>([])
  const [agents, setAgents] = useState<MemoryAgentScope[]>([])
  const [categories, setCategories] = useState<string[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [form, setForm] = useState<MemoryFormState>(() => buildInitialForm([], []))
  const [isLoading, setIsLoading] = useState(true)
  const [isSaving, setIsSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [scopeFilter, setScopeFilter] = useState<ScopeFilter>('all')
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('active')
  const deferredSearch = useDeferredValue(search)
  const selectedEntry = useMemo(
    () => entries.find((entry) => entry.id === selectedId) ?? null,
    [entries, selectedId],
  )

  useEffect(() => {
    let active = true

    async function load() {
      setIsLoading(true)
      setError(null)

      try {
        const response = await fetchMemoryEntries()
        if (!active) {
          return
        }

        setEntries(response.entries)
        setAgents(response.agents)
        setCategories(response.categories)

        startTransition(() => {
          if (response.entries[0]) {
            setSelectedId(response.entries[0].id)
            setForm(formFromEntry(response.entries[0]))
          } else {
            setSelectedId(null)
            setForm(buildInitialForm(response.categories, response.agents))
          }
        })
      } catch (loadError) {
        if (!active) {
          return
        }

        setError(loadError instanceof Error ? loadError.message : 'Failed to load memory entries.')
      } finally {
        if (active) {
          setIsLoading(false)
        }
      }
    }

    void load()

    return () => {
      active = false
    }
  }, [])

  const filteredEntries = useMemo(() => {
    const normalizedSearch = deferredSearch.trim().toLowerCase()

    return entries.filter((entry) => {
      if (scopeFilter !== 'all' && entry.visibility !== scopeFilter) {
        return false
      }

      if (statusFilter !== 'all') {
        if (statusFilter === 'active' && !entry.active) {
          return false
        }

        if (statusFilter === 'inactive' && entry.active) {
          return false
        }
      }

      if (!normalizedSearch) {
        return true
      }

      return [
        entry.content,
        entry.category,
        entry.agent?.name ?? '',
        entry.source,
      ].some((value) => value.toLowerCase().includes(normalizedSearch))
    })
  }, [deferredSearch, entries, scopeFilter, statusFilter])

  async function persistEntry() {
    setIsSaving(true)
    setError(null)

    try {
      const payload = buildPayload(form)
      const nextEntry = selectedEntry
        ? await updateMemoryEntry(selectedEntry.id, payload)
        : await createMemoryEntry(payload)

      setEntries((currentEntries) => {
        const existingIndex = currentEntries.findIndex((entry) => entry.id === nextEntry.id)
        if (existingIndex === -1) {
          return [nextEntry, ...currentEntries]
        }

        const nextEntries = currentEntries.slice()
        nextEntries[existingIndex] = nextEntry
        return nextEntries
      })

      startTransition(() => {
        setSelectedId(nextEntry.id)
        setForm(formFromEntry(nextEntry))
      })
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : 'Failed to save the memory entry.')
    } finally {
      setIsSaving(false)
    }
  }

  async function deactivateSelectedEntry() {
    if (!selectedEntry) {
      return
    }

    setIsSaving(true)
    setError(null)

    try {
      const nextEntry = await deactivateMemoryEntry(
        selectedEntry.id,
        form.reason || 'Deactivated from memory inspector',
      )

      setEntries((currentEntries) =>
        currentEntries.map((entry) =>
          entry.id === nextEntry.id ? nextEntry : entry,
        ),
      )
      setForm(formFromEntry(nextEntry))
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : 'Failed to deactivate the memory entry.')
    } finally {
      setIsSaving(false)
    }
  }

  function beginNewEntry() {
    setSelectedId(null)
    setForm(buildInitialForm(categories, agents))
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-4">
      <section className="rounded-[32px] border border-white/10 bg-[linear-gradient(135deg,rgba(8,15,30,0.94),rgba(17,24,39,0.88))] p-6 shadow-[0_24px_90px_rgba(2,6,23,0.35)] sm:p-7">
        <div className="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
          <div className="max-w-3xl">
            <p className="text-[11px] font-semibold uppercase tracking-[0.3em] text-emerald-100/80">
              Structured Memory
            </p>
            <h2 className="mt-3 text-3xl font-semibold tracking-tight text-slate-50">
              Durable facts, not documents
            </h2>
            <p className="mt-3 text-sm leading-6 text-slate-400">
              Structured memory lives alongside the vault. Memory is compact,
              curated, and optimized for recall inside the agent runtime. The
              vault remains the richer document layer for user-authored notes,
              files, and long-form context.
            </p>
          </div>

          <div className="grid gap-3 sm:grid-cols-2 lg:max-w-xl">
            <div className="rounded-[24px] border border-emerald-300/20 bg-emerald-400/10 px-4 py-4">
              <p className="text-[11px] font-semibold uppercase tracking-[0.24em] text-emerald-100/80">
                Shared Memory
              </p>
              <p className="mt-2 text-sm leading-6 text-emerald-50/90">
                User-wide preferences, instructions, and identity facts every
                compatible agent should carry forward.
              </p>
            </div>

            <div className="rounded-[24px] border border-amber-300/20 bg-amber-400/10 px-4 py-4">
              <p className="text-[11px] font-semibold uppercase tracking-[0.24em] text-amber-100/80">
                Private Memory
              </p>
              <p className="mt-2 text-sm leading-6 text-amber-50/90">
                Specialist context that belongs to one agent without polluting
                the shared memory pool.
              </p>
            </div>
          </div>
        </div>
      </section>

      <section className="grid min-h-0 flex-1 gap-4 xl:grid-cols-[1.1fr_0.9fr]">
        <div className="flex min-h-0 flex-col rounded-[28px] border border-white/10 bg-white/[0.04] p-5 shadow-[0_16px_60px_rgba(2,6,23,0.24)] backdrop-blur-xl">
          <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <p className="text-lg font-medium text-slate-50">Memory inspector</p>
              <p className="mt-1 text-sm text-slate-400">
                Review what the system may recall later and prune low-signal entries.
              </p>
            </div>

            <button
              type="button"
              onClick={beginNewEntry}
              className="inline-flex items-center justify-center rounded-2xl border border-cyan-300/30 bg-cyan-400/10 px-4 py-2 text-sm font-medium text-cyan-100 transition hover:border-cyan-200/50 hover:bg-cyan-400/15"
            >
              New memory
            </button>
          </div>

          <div className="mt-4 grid gap-3 md:grid-cols-[1.5fr_1fr_1fr]">
            <input
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Search content, category, or scope"
              className="rounded-2xl border border-white/10 bg-slate-950/40 px-4 py-3 text-sm text-slate-100 outline-none transition placeholder:text-slate-500 focus:border-cyan-300/40"
            />

            <select
              value={scopeFilter}
              onChange={(event) => setScopeFilter(event.target.value as ScopeFilter)}
              className="rounded-2xl border border-white/10 bg-slate-950/40 px-4 py-3 text-sm text-slate-100 outline-none transition focus:border-cyan-300/40"
            >
              <option value="all">All scopes</option>
              <option value="shared">Shared only</option>
              <option value="private">Private only</option>
            </select>

            <select
              value={statusFilter}
              onChange={(event) => setStatusFilter(event.target.value as StatusFilter)}
              className="rounded-2xl border border-white/10 bg-slate-950/40 px-4 py-3 text-sm text-slate-100 outline-none transition focus:border-cyan-300/40"
            >
              <option value="active">Active only</option>
              <option value="inactive">Inactive only</option>
              <option value="all">All statuses</option>
            </select>
          </div>

          <div className="mt-4 min-h-0 flex-1 overflow-y-auto pr-1">
            {isLoading ? (
              <div className="rounded-[24px] border border-dashed border-white/10 bg-slate-950/30 p-6 text-sm text-slate-400">
                Loading structured memory…
              </div>
            ) : filteredEntries.length === 0 ? (
              <div className="rounded-[24px] border border-dashed border-white/10 bg-slate-950/30 p-6 text-sm text-slate-400">
                No memory entries match the current filters.
              </div>
            ) : (
              <div className="space-y-3">
                {filteredEntries.map((entry) => {
                  const isSelected = entry.id === selectedId

                  return (
                    <button
                      key={entry.id}
                      type="button"
                      onClick={() => {
                        setSelectedId(entry.id)
                        setForm(formFromEntry(entry))
                      }}
                      className={`w-full rounded-[24px] border p-4 text-left transition ${
                        isSelected
                          ? 'border-cyan-300/40 bg-cyan-400/10 shadow-[0_16px_40px_rgba(34,211,238,0.08)]'
                          : 'border-white/10 bg-slate-950/35 hover:border-white/20 hover:bg-slate-950/55'
                      }`}
                    >
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="rounded-full border border-white/10 bg-white/[0.06] px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.24em] text-slate-200">
                          {entry.category}
                        </span>
                        <span
                          className={`rounded-full px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.24em] ${
                            entry.visibility === 'shared'
                              ? 'border border-emerald-300/20 bg-emerald-400/10 text-emerald-100'
                              : 'border border-amber-300/20 bg-amber-400/10 text-amber-100'
                          }`}
                        >
                          {entry.visibility}
                        </span>
                        {!entry.active && (
                          <span className="rounded-full border border-rose-300/20 bg-rose-400/10 px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.24em] text-rose-100">
                            inactive
                          </span>
                        )}
                      </div>

                      <p className="mt-3 text-sm leading-6 text-slate-100">
                        {entry.content}
                      </p>

                      <div className="mt-4 flex flex-wrap gap-4 text-xs text-slate-400">
                        <span>Importance {entry.importance}/10</span>
                        <span>Confidence {entry.confidence.toFixed(2)}</span>
                        <span>{entry.agent?.name ?? 'Shared pool'}</span>
                        <span>Updated {formatRelativeDate(entry.updated_at)}</span>
                      </div>
                    </button>
                  )
                })}
              </div>
            )}
          </div>
        </div>

        <div className="flex min-h-0 flex-col rounded-[28px] border border-white/10 bg-[linear-gradient(180deg,rgba(10,15,28,0.92),rgba(5,10,21,0.88))] p-5 shadow-[0_16px_60px_rgba(2,6,23,0.24)]">
          <div className="flex items-start justify-between gap-4">
            <div>
              <p className="text-lg font-medium text-slate-50">
                {selectedEntry ? 'Edit memory entry' : 'Create memory entry'}
              </p>
              <p className="mt-1 text-sm text-slate-400">
                Shape what the system keeps in fast-recall memory without touching the vault.
              </p>
            </div>

            {selectedEntry && (
              <span className="rounded-full border border-white/10 bg-white/[0.05] px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.24em] text-slate-300">
                {selectedEntry.id.slice(0, 8)}
              </span>
            )}
          </div>

          <div className="mt-5 grid gap-4">
            <label className="grid gap-2">
              <span className="text-sm font-medium text-slate-200">Memory content</span>
              <textarea
                value={form.content}
                onChange={(event) =>
                  setForm((currentForm) => ({ ...currentForm, content: event.target.value }))
                }
                rows={7}
                className="rounded-[24px] border border-white/10 bg-slate-950/45 px-4 py-3 text-sm leading-6 text-slate-100 outline-none transition placeholder:text-slate-500 focus:border-cyan-300/40"
                placeholder="User prefers direct answers with code references."
              />
            </label>

            <div className="grid gap-4 md:grid-cols-2">
              <label className="grid gap-2">
                <span className="text-sm font-medium text-slate-200">Category</span>
                <select
                  value={form.category}
                  onChange={(event) =>
                    setForm((currentForm) => ({ ...currentForm, category: event.target.value }))
                  }
                  className="rounded-2xl border border-white/10 bg-slate-950/45 px-4 py-3 text-sm text-slate-100 outline-none transition focus:border-cyan-300/40"
                >
                  {categories.map((category) => (
                    <option key={category} value={category}>
                      {category}
                    </option>
                  ))}
                </select>
              </label>

              <label className="grid gap-2">
                <span className="text-sm font-medium text-slate-200">Visibility</span>
                <select
                  value={form.visibility}
                  onChange={(event) =>
                    setForm((currentForm) => ({
                      ...currentForm,
                      visibility: event.target.value as 'shared' | 'private',
                    }))
                  }
                  className="rounded-2xl border border-white/10 bg-slate-950/45 px-4 py-3 text-sm text-slate-100 outline-none transition focus:border-cyan-300/40"
                >
                  <option value="shared">Shared</option>
                  <option value="private">Private</option>
                </select>
              </label>
            </div>

            {form.visibility === 'private' && (
              <label className="grid gap-2">
                <span className="text-sm font-medium text-slate-200">Private agent scope</span>
                <select
                  value={form.agentId}
                  onChange={(event) =>
                    setForm((currentForm) => ({ ...currentForm, agentId: event.target.value }))
                  }
                  className="rounded-2xl border border-white/10 bg-slate-950/45 px-4 py-3 text-sm text-slate-100 outline-none transition focus:border-cyan-300/40"
                >
                  {agents.map((agent) => (
                    <option key={agent.id} value={agent.id}>
                      {agent.name}
                    </option>
                  ))}
                </select>
              </label>
            )}

            <div className="grid gap-4 md:grid-cols-2">
              <label className="grid gap-2">
                <span className="text-sm font-medium text-slate-200">Importance</span>
                <input
                  type="number"
                  min={1}
                  max={10}
                  value={form.importance}
                  onChange={(event) =>
                    setForm((currentForm) => ({ ...currentForm, importance: event.target.value }))
                  }
                  className="rounded-2xl border border-white/10 bg-slate-950/45 px-4 py-3 text-sm text-slate-100 outline-none transition focus:border-cyan-300/40"
                />
              </label>

              <label className="grid gap-2">
                <span className="text-sm font-medium text-slate-200">Confidence</span>
                <input
                  type="number"
                  min={0}
                  max={1}
                  step={0.05}
                  value={form.confidence}
                  onChange={(event) =>
                    setForm((currentForm) => ({ ...currentForm, confidence: event.target.value }))
                  }
                  className="rounded-2xl border border-white/10 bg-slate-950/45 px-4 py-3 text-sm text-slate-100 outline-none transition focus:border-cyan-300/40"
                />
              </label>
            </div>

            <label className="grid gap-2">
              <span className="text-sm font-medium text-slate-200">Reason for change</span>
              <input
                value={form.reason}
                onChange={(event) =>
                  setForm((currentForm) => ({ ...currentForm, reason: event.target.value }))
                }
                className="rounded-2xl border border-white/10 bg-slate-950/45 px-4 py-3 text-sm text-slate-100 outline-none transition placeholder:text-slate-500 focus:border-cyan-300/40"
                placeholder="Why this memory was added or corrected"
              />
            </label>

            {selectedEntry && (
              <div className="grid gap-3 rounded-[24px] border border-white/10 bg-slate-950/35 p-4 text-xs text-slate-400 sm:grid-cols-2">
                <div>
                  <p className="font-semibold uppercase tracking-[0.24em] text-slate-300">
                    Provenance
                  </p>
                  <p className="mt-2">Source: {selectedEntry.source}</p>
                  <p>Session: {selectedEntry.session_id ?? 'None'}</p>
                  <p>Message: {selectedEntry.source_message_id ?? 'None'}</p>
                </div>

                <div>
                  <p className="font-semibold uppercase tracking-[0.24em] text-slate-300">
                    Usage
                  </p>
                  <p className="mt-2">Access count: {selectedEntry.access_count}</p>
                  <p>Last recalled: {formatRelativeDate(selectedEntry.last_accessed_at)}</p>
                  <p>Fingerprint: {selectedEntry.fingerprint.slice(0, 12)}…</p>
                </div>
              </div>
            )}

            {error && (
              <div className="rounded-2xl border border-rose-300/20 bg-rose-400/10 px-4 py-3 text-sm text-rose-100">
                {error}
              </div>
            )}
          </div>

          <div className="mt-5 flex flex-wrap gap-3">
            <button
              type="button"
              disabled={isSaving || form.content.trim().length === 0}
              onClick={() => {
                void persistEntry()
              }}
              className="inline-flex items-center justify-center rounded-2xl bg-[linear-gradient(135deg,rgba(34,211,238,0.82),rgba(59,130,246,0.78))] px-4 py-2.5 text-sm font-medium text-slate-950 transition hover:brightness-105 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {isSaving ? 'Saving…' : selectedEntry ? 'Save changes' : 'Create memory'}
            </button>

            {selectedEntry && selectedEntry.active && (
              <button
                type="button"
                disabled={isSaving}
                onClick={() => {
                  void deactivateSelectedEntry()
                }}
                className="inline-flex items-center justify-center rounded-2xl border border-rose-300/20 bg-rose-400/10 px-4 py-2.5 text-sm font-medium text-rose-100 transition hover:border-rose-200/40 hover:bg-rose-400/15 disabled:cursor-not-allowed disabled:opacity-60"
              >
                Deactivate
              </button>
            )}
          </div>
        </div>
      </section>
    </div>
  )
}
