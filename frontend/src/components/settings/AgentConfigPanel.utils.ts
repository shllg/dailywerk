import type {
  AgentConfig,
  AgentConfigUpdate,
  AgentDefaults,
  AgentIdentity,
  AgentThinking,
} from '../../types/agent'

export const INPUT_CLASS =
  'w-full rounded-2xl border border-white/10 bg-slate-950/70 px-4 py-3 text-sm text-slate-100 outline-none transition placeholder:text-slate-500 focus:border-blue-400/40'
export const TEXTAREA_CLASS = `${INPUT_CLASS} min-h-32 font-mono`
export const SECTION_CLASS =
  'rounded-[28px] border border-white/10 bg-white/[0.03] p-5'

export interface AgentConfigFormState {
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

export function formStateFromAgent(agent: AgentConfig): AgentConfigFormState {
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

export function buildUpdatePayload(
  form: AgentConfigFormState,
): AgentConfigUpdate {
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

export function buildResetConfirmation(
  agent: AgentConfig,
  defaults: AgentDefaults,
): string {
  return [
    `Reset "${agent.name}" to the factory defaults?`,
    '',
    `Name: ${defaults.name}`,
    `Model: ${defaults.model_id}`,
  ].join('\n')
}

function blankToNull(value: string): string | null {
  const trimmed = value.trim()
  return trimmed ? trimmed : null
}

function normalizeIdentity(
  identity: AgentConfigFormState['identity'],
): AgentIdentity {
  const normalizedIdentity: AgentIdentity = {}

  if (identity.persona.trim()) normalizedIdentity.persona = identity.persona.trim()
  if (identity.tone.trim()) normalizedIdentity.tone = identity.tone.trim()
  if (identity.constraints.trim()) {
    normalizedIdentity.constraints = identity.constraints.trim()
  }

  return normalizedIdentity
}

function normalizeThinking(
  thinking: AgentConfigFormState['thinking'],
): AgentThinking {
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
