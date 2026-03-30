export interface Message {
  id: string
  role: 'user' | 'assistant' | 'system'
  content: string
  timestamp: string
  status: 'sending' | 'sent' | 'streaming' | 'error'
  agentName?: string
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

export interface Agent {
  slug: string
  name: string
}

export interface ChatState {
  sessionId: string
  agent: Agent
  messages: Message[]
}
