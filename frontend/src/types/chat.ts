export interface Message {
  id: string
  role: 'user' | 'assistant' | 'system'
  content: string
  agentName?: string
  timestamp: string
  status: 'sending' | 'sent' | 'streaming' | 'error'
  toolCalls?: ToolCall[]
  thinkingContent?: string
}

export interface ToolCall {
  id: string
  name: string
  args: Record<string, unknown>
  result?: string
  status: 'pending' | 'running' | 'completed' | 'error'
}

export interface Session {
  id: string
  title: string
  lastMessage?: string
  lastMessageAt: string
  agentName: string
  messageCount: number
}

export interface Agent {
  slug: string
  name: string
  description: string
  color: string
}
