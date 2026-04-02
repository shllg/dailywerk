export interface MemoryAgentScope {
  id: string
  name: string
  slug: string
  memory_isolation: string
}

export interface MemoryVersion {
  id: string
  action: string
  reason: string | null
  created_at: string
  snapshot: Record<string, unknown>
}

export interface MemoryEntry {
  id: string
  category: string
  content: string
  source: string
  importance: number
  confidence: number
  active: boolean
  visibility: 'shared' | 'private'
  fingerprint: string
  expires_at: string | null
  access_count: number
  last_accessed_at: string | null
  updated_at: string
  metadata: Record<string, unknown>
  agent: MemoryAgentScope | null
  session_id: string | null
  source_message_id: string | null
  versions?: MemoryVersion[]
}

export interface MemoryIndexResponse {
  entries: MemoryEntry[]
  agents: MemoryAgentScope[]
  categories: string[]
}

export interface MemoryMutationInput {
  agent_id?: string | null
  category: string
  confidence: number
  content: string
  expires_at?: string | null
  importance: number
  metadata?: Record<string, unknown>
  reason?: string
  visibility: 'shared' | 'private'
}
