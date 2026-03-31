import { useEffect, useState } from 'react'
import { fetchAgentConfig, resetAgentConfig, updateAgentConfig } from '../../services/agentApi'
import type {
  AgentConfig,
  AgentConfigResponse,
  AgentConfigUpdate,
  AgentDefaults,
} from '../../types/agent'
import { AgentConfigPanel } from './AgentConfigPanel'

export interface SettingsDrawerProps {
  agentId: string | null
  agentName: string | null
  isOpen: boolean
  onAgentUpdated: (agent: AgentConfig) => void
  onClose: () => void
}

function hydrateDrawer(
  response: AgentConfigResponse,
  setAgent: (agent: AgentConfig) => void,
  setDefaults: (defaults: AgentDefaults) => void,
) {
  setAgent(response.agent)
  setDefaults(response.defaults)
}

export function SettingsDrawer({
  agentId,
  agentName,
  isOpen,
  onAgentUpdated,
  onClose,
}: SettingsDrawerProps) {
  const [agent, setAgent] = useState<AgentConfig | null>(null)
  const [defaults, setDefaults] = useState<AgentDefaults | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [isLoading, setIsLoading] = useState(false)
  const [isSaving, setIsSaving] = useState(false)
  const [isResetting, setIsResetting] = useState(false)

  useEffect(() => {
    if (!isOpen || !agentId) {
      return
    }

    let cancelled = false
    setIsLoading(true)
    setError(null)

    fetchAgentConfig(agentId)
      .then((response) => {
        if (cancelled) return

        setAgent(response.agent)
        setDefaults(response.defaults)
      })
      .catch((fetchError: Error) => {
        if (cancelled) return

        setAgent(null)
        setDefaults(null)
        setError(fetchError.message)
      })
      .finally(() => {
        if (!cancelled) {
          setIsLoading(false)
        }
      })

    return () => {
      cancelled = true
    }
  }, [agentId, isOpen])

  async function handleSave(updates: AgentConfigUpdate) {
    if (!agentId) return

    setIsSaving(true)
    setError(null)

    try {
      const response = await updateAgentConfig(agentId, updates)
      hydrateDrawer(response, setAgent, setDefaults)
      onAgentUpdated(response.agent)
    } catch (saveError) {
      const message = saveError instanceof Error ? saveError.message : 'HTTP 500'
      setError(message)
    } finally {
      setIsSaving(false)
    }
  }

  async function handleReset() {
    if (!agentId) return

    setIsResetting(true)
    setError(null)

    try {
      const response = await resetAgentConfig(agentId)
      hydrateDrawer(response, setAgent, setDefaults)
      onAgentUpdated(response.agent)
    } catch (resetError) {
      const message = resetError instanceof Error ? resetError.message : 'HTTP 500'
      setError(message)
    } finally {
      setIsResetting(false)
    }
  }

  return (
    <div className="drawer-side z-50">
      <label
        aria-label="Close settings"
        className="drawer-overlay"
        onClick={onClose}
      />

      <aside className="min-h-full w-full max-w-xl border-l border-white/10 bg-[#061120] text-white shadow-2xl shadow-slate-950/60 backdrop-blur-xl">
        <div className="flex h-full flex-col px-5 pb-5 pt-4 sm:px-6">
          <div className="flex items-start justify-between gap-4 border-b border-white/10 pb-4">
            <div>
              <p className="text-xs font-semibold uppercase tracking-[0.24em] text-blue-200">
                Agent Settings
              </p>
              <h2 className="mt-2 text-2xl font-semibold tracking-tight text-slate-50">
                {agent?.name || agentName || 'Active agent'}
              </h2>
              <p className="mt-1 text-sm text-slate-400">
                Configure prompt, identity, provider, and thinking defaults.
              </p>
            </div>

            <button
              type="button"
              onClick={onClose}
              className="rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm font-medium text-slate-200 transition hover:border-white/20 hover:bg-white/10"
            >
              Close
            </button>
          </div>

          <div className="mt-5 flex-1 min-h-0">
            {!agentId && (
              <div className="flex h-full items-center justify-center rounded-[28px] border border-white/10 bg-white/[0.03] px-6 text-center text-sm text-slate-400">
                Load a chat session before editing the active agent.
              </div>
            )}

            {agentId && isLoading && (
              <div className="flex h-full items-center justify-center rounded-[28px] border border-white/10 bg-white/[0.03] px-6 text-center text-sm text-slate-400">
                Loading agent settings...
              </div>
            )}

            {agentId && !isLoading && error && !agent && (
              <div className="flex h-full items-center justify-center rounded-[28px] border border-red-500/20 bg-white/[0.03] px-6 text-center">
                <div className="max-w-sm">
                  <p className="text-base font-medium text-red-200">
                    Settings failed to load
                  </p>
                  <p className="mt-2 text-sm text-slate-400">{error}</p>
                  <button
                    type="button"
                    onClick={() => {
                      setError(null)
                      setIsLoading(true)
                      void fetchAgentConfig(agentId)
                        .then((response) => {
                          hydrateDrawer(response, setAgent, setDefaults)
                        })
                        .catch((retryError: Error) => {
                          setError(retryError.message)
                        })
                        .finally(() => {
                          setIsLoading(false)
                        })
                    }}
                    className="mt-5 rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm font-medium text-slate-200 transition hover:border-white/20 hover:bg-white/10"
                  >
                    Retry
                  </button>
                </div>
              </div>
            )}

            {agent && defaults && (
              <div className="flex h-full flex-col">
                {error && (
                  <div className="mb-4 rounded-2xl border border-red-500/20 bg-red-500/10 px-4 py-3 text-sm text-red-100">
                    {error}
                  </div>
                )}

                <AgentConfigPanel
                  agent={agent}
                  defaults={defaults}
                  isSaving={isSaving}
                  isResetting={isResetting}
                  onSave={handleSave}
                  onReset={handleReset}
                />
              </div>
            )}
          </div>
        </div>
      </aside>
    </div>
  )
}
