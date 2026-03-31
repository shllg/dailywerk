import type { AgentConfigResponse, AgentConfigUpdate } from '../types/agent'
import { apiRequest } from './api'

export function fetchAgentConfig(agentId: string): Promise<AgentConfigResponse> {
  return apiRequest<AgentConfigResponse>(`/agents/${agentId}`)
}

export function updateAgentConfig(
  agentId: string,
  updates: Partial<AgentConfigUpdate>,
): Promise<AgentConfigResponse> {
  return apiRequest<AgentConfigResponse>(`/agents/${agentId}`, {
    method: 'PATCH',
    body: JSON.stringify({ agent: updates }),
  })
}

export function resetAgentConfig(agentId: string): Promise<AgentConfigResponse> {
  return apiRequest<AgentConfigResponse>(`/agents/${agentId}/reset`, {
    method: 'POST',
  })
}
