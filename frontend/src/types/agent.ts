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
  memory_isolation: string
  provider: string | null
  temperature: number
  instructions: string | null
  soul: string | null
  identity: AgentIdentity
  params: Record<string, unknown>
  thinking: AgentThinking
  tool_names: string[]
  is_default: boolean
  active: boolean
}

export type AgentConfigUpdate = Partial<Pick<
  AgentConfig,
  | 'name'
  | 'model_id'
  | 'memory_isolation'
  | 'provider'
  | 'temperature'
  | 'instructions'
  | 'soul'
  | 'identity'
  | 'thinking'
  | 'tool_names'
>>

export type AgentDefaults = Pick<
  AgentConfig,
  | 'name'
  | 'model_id'
  | 'memory_isolation'
  | 'provider'
  | 'temperature'
  | 'instructions'
  | 'soul'
  | 'identity'
  | 'params'
  | 'thinking'
  | 'tool_names'
>

export interface AgentConfigResponse {
  agent: AgentConfig
  defaults: AgentDefaults
}
