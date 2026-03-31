import { type FormEvent, useEffect, useState } from 'react'
import type {
  AgentConfig,
  AgentConfigUpdate,
  AgentDefaults,
  AgentIdentity,
  AgentThinking,
} from '../../types/agent'

const INPUT_CLASS =
  'w-full rounded-2xl border border-white/10 bg-slate-950/70 px-4 py-3 text-sm text-slate-100 outline-none transition placeholder:text-slate-500 focus:border-blue-400/40'
const TEXTAREA_CLASS = `${INPUT_CLASS} min-h-32 font-mono`
const SECTION_CLASS =
  'rounded-[28px] border border-white/10 bg-white/[0.03] p-5'

interface AgentConfigFormState {
  name: string
  model_id: string
  provider: string
  temperature: string
  instructions: string
  soul: string
  identity: {
    persona: string
    tone: string
    constraints: string
  }
  thinking: {
    enabled: boolean
    budget_tokens: string
  }
}

export interface AgentConfigPanelProps {
  agent: AgentConfig
  defaults: AgentDefaults
  isSaving: boolean
  isResetting: boolean
  onReset: () => Promise<void>
  onSave: (updates: AgentConfigUpdate) => Promise<void>
}

function blankToNull(value: string): string | null {
  const trimmed = value.trim()
  return trimmed ? trimmed : null
}

function normalizeIdentity(identity: AgentConfigFormState['identity']): AgentIdentity {
  const normalizedIdentity: AgentIdentity = {}

  if (identity.persona.trim()) normalizedIdentity.persona = identity.persona.trim()
  if (identity.tone.trim()) normalizedIdentity.tone = identity.tone.trim()
  if (identity.constraints.trim()) {
    normalizedIdentity.constraints = identity.constraints.trim()
  }

  return normalizedIdentity
}

function normalizeThinking(thinking: AgentConfigFormState['thinking']): AgentThinking {
  if (!thinking.enabled) {
    return {}
  }

  const normalizedThinking: AgentThinking = { enabled: true }
  const trimmedBudget = thinking.budget_tokens.trim()

  if (trimmedBudget) {
    normalizedThinking.budget_tokens = Number(trimmedBudget)
  }

  return normalizedThinking
}

function formStateFromAgent(agent: AgentConfig): AgentConfigFormState {
  return {
    name: agent.name,
    model_id: agent.model_id,
    provider: agent.provider ?? '',
    temperature: String(agent.temperature),
    instructions: agent.instructions ?? '',
    soul: agent.soul ?? '',
    identity: {
      persona: agent.identity.persona ?? '',
      tone: agent.identity.tone ?? '',
      constraints: agent.identity.constraints ?? '',
    },
    thinking: {
      enabled: agent.thinking.enabled ?? false,
      budget_tokens: agent.thinking.budget_tokens
        ? String(agent.thinking.budget_tokens)
        : '',
    },
  }
}

function buildUpdatePayload(form: AgentConfigFormState): AgentConfigUpdate {
  return {
    name: form.name.trim(),
    model_id: form.model_id.trim(),
    provider: blankToNull(form.provider),
    temperature: Number(form.temperature),
    instructions: blankToNull(form.instructions),
    soul: blankToNull(form.soul),
    identity: normalizeIdentity(form.identity),
    thinking: normalizeThinking(form.thinking),
  }
}

export function AgentConfigPanel({
  agent,
  defaults,
  isSaving,
  isResetting,
  onReset,
  onSave,
}: AgentConfigPanelProps) {
  const [form, setForm] = useState<AgentConfigFormState>(() =>
    formStateFromAgent(agent),
  )

  useEffect(() => {
    setForm(formStateFromAgent(agent))
  }, [agent])

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    await onSave(buildUpdatePayload(form))
  }

  async function handleReset() {
    const confirmed = window.confirm(
      [
        `Reset "${agent.name}" to the factory defaults?`,
        '',
        `Name: ${defaults.name}`,
        `Model: ${defaults.model_id}`,
      ].join('\n'),
    )

    if (!confirmed) {
      return
    }

    await onReset()
  }

  return (
    <form onSubmit={handleSubmit} className="flex h-full flex-col">
      <div className="flex-1 space-y-4 overflow-y-auto pr-1">
        <section className={SECTION_CLASS}>
          <div className="mb-4">
            <p className="text-sm font-semibold text-slate-100">Basic</p>
            <p className="mt-1 text-xs text-slate-400">
              Name, model, and temperature define the default runtime profile.
            </p>
          </div>

          <div className="space-y-4">
            <label className="block">
              <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                Name
              </span>
              <input
                type="text"
                required
                value={form.name}
                onChange={(event) =>
                  setForm((current) => ({ ...current, name: event.target.value }))
                }
                className={INPUT_CLASS}
              />
            </label>

            <label className="block">
              <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                Model ID
              </span>
              <input
                type="text"
                required
                value={form.model_id}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    model_id: event.target.value,
                  }))
                }
                className={INPUT_CLASS}
              />
            </label>

            <div className="grid gap-4 sm:grid-cols-2">
              <label className="block">
                <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                  Provider
                </span>
                <input
                  type="text"
                  value={form.provider}
                  onChange={(event) =>
                    setForm((current) => ({
                      ...current,
                      provider: event.target.value,
                    }))
                  }
                  placeholder="Auto-detect"
                  className={INPUT_CLASS}
                />
              </label>

              <label className="block">
                <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                  Temperature
                </span>
                <input
                  type="number"
                  required
                  step="0.1"
                  value={form.temperature}
                  onChange={(event) =>
                    setForm((current) => ({
                      ...current,
                      temperature: event.target.value,
                    }))
                  }
                  className={INPUT_CLASS}
                />
              </label>
            </div>
          </div>
        </section>

        <div className="collapse collapse-arrow rounded-[28px] border border-white/10 bg-white/[0.03]">
          <input type="checkbox" />
          <div className="collapse-title text-sm font-semibold text-slate-100">
            Advanced
          </div>
          <div className="collapse-content space-y-4 border-t border-white/10 pt-4">
            <label className="block">
              <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                Instructions
              </span>
              <textarea
                value={form.instructions}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    instructions: event.target.value,
                  }))
                }
                className={TEXTAREA_CLASS}
              />
            </label>

            <label className="block">
              <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                Soul
              </span>
              <textarea
                value={form.soul}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    soul: event.target.value,
                  }))
                }
                className={TEXTAREA_CLASS}
              />
            </label>
          </div>
        </div>

        <div className="collapse collapse-arrow rounded-[28px] border border-white/10 bg-white/[0.03]">
          <input type="checkbox" />
          <div className="collapse-title text-sm font-semibold text-slate-100">
            Identity
          </div>
          <div className="collapse-content space-y-4 border-t border-white/10 pt-4">
            <label className="block">
              <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                Persona
              </span>
              <textarea
                value={form.identity.persona}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    identity: {
                      ...current.identity,
                      persona: event.target.value,
                    },
                  }))
                }
                className={TEXTAREA_CLASS}
              />
            </label>

            <label className="block">
              <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                Tone
              </span>
              <textarea
                value={form.identity.tone}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    identity: {
                      ...current.identity,
                      tone: event.target.value,
                    },
                  }))
                }
                className={TEXTAREA_CLASS}
              />
            </label>

            <label className="block">
              <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                Constraints
              </span>
              <textarea
                value={form.identity.constraints}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    identity: {
                      ...current.identity,
                      constraints: event.target.value,
                    },
                  }))
                }
                className={TEXTAREA_CLASS}
              />
            </label>
          </div>
        </div>

        <div className="collapse collapse-arrow rounded-[28px] border border-white/10 bg-white/[0.03]">
          <input type="checkbox" />
          <div className="collapse-title text-sm font-semibold text-slate-100">
            Thinking
          </div>
          <div className="collapse-content space-y-4 border-t border-white/10 pt-4">
            <label className="flex items-center justify-between rounded-2xl border border-white/10 bg-slate-950/70 px-4 py-3">
              <div>
                <span className="block text-sm font-medium text-slate-100">
                  Enable Thinking
                </span>
                <span className="mt-1 block text-xs text-slate-400">
                  Apply the provider thinking budget on the next message.
                </span>
              </div>
              <input
                type="checkbox"
                className="toggle border-white/20 bg-slate-900 [--tglbg:theme(colors.blue.400)]"
                checked={form.thinking.enabled}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    thinking: {
                      ...current.thinking,
                      enabled: event.target.checked,
                    },
                  }))
                }
              />
            </label>

            <label className="block">
              <span className="mb-2 block text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">
                Budget Tokens
              </span>
              <input
                type="number"
                min="1"
                max="100000"
                value={form.thinking.budget_tokens}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    thinking: {
                      ...current.thinking,
                      budget_tokens: event.target.value,
                    },
                  }))
                }
                disabled={!form.thinking.enabled}
                placeholder="10000"
                className={`${INPUT_CLASS} disabled:cursor-not-allowed disabled:border-white/5 disabled:text-slate-500`}
              />
            </label>
          </div>
        </div>
      </div>

      <div className="mt-6 flex flex-col gap-3 border-t border-white/10 pt-4 sm:flex-row sm:items-center sm:justify-between">
        <p className="text-xs text-slate-400">
          Changes apply to the next message in the active chat session.
        </p>

        <div className="flex flex-col gap-3 sm:flex-row">
          <button
            type="button"
            onClick={handleReset}
            disabled={isSaving || isResetting}
            className="rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm font-medium text-slate-200 transition hover:border-white/20 hover:bg-white/10 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {isResetting ? 'Resetting...' : 'Reset to defaults'}
          </button>

          <button
            type="submit"
            disabled={isSaving || isResetting}
            className="rounded-full border border-blue-400/30 bg-blue-500/15 px-4 py-2 text-sm font-medium text-blue-100 transition hover:border-blue-300/40 hover:bg-blue-500/25 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {isSaving ? 'Saving...' : 'Save'}
          </button>
        </div>
      </div>
    </form>
  )
}
