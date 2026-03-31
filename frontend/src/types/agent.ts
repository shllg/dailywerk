export interface AgentIdentity {
  persona?: string
  tone?: string
  constraints?: string
}

export interface AgentThinking {
  enabled?: boolean
  budget_tokens?: number
}

export interface AgentConfig {
  id: string
  slug: string
  name: string
  model_id: string
  provider: string | null
  temperature: number
  instructions: string | null
  soul: string | null
  identity: AgentIdentity
  params: Record<string, unknown>
  thinking: AgentThinking
  is_default: boolean
  active: boolean
}

export type AgentConfigUpdate = Pick<
  AgentConfig,
  | 'name'
  | 'model_id'
  | 'provider'
  | 'temperature'
  | 'instructions'
  | 'soul'
  | 'identity'
  | 'thinking'
>

export type AgentDefaults = Pick<
  AgentConfig,
  | 'name'
  | 'model_id'
  | 'provider'
  | 'temperature'
  | 'instructions'
  | 'soul'
  | 'identity'
  | 'params'
  | 'thinking'
>

export interface AgentConfigResponse {
  agent: AgentConfig
  defaults: AgentDefaults
}
