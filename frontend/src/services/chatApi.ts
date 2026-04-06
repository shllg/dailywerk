import type { ChatState, Message } from '../types/chat'
import { apiRequest } from './api'

interface ChatApiMessage {
  id: string
  role: Message['role']
  content: string
  timestamp: string
}

interface ChatApiResponse {
  session_id: string
  agent: ChatState['agent']
  messages: ChatApiMessage[]
  session_summary?: string
}

function formatTimestamp(timestamp: string) {
  const date = new Date(timestamp)
  if (Number.isNaN(date.getTime())) {
    return timestamp
  }

  return date.toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
  })
}

function normalizeMessage(message: ChatApiMessage): Message {
  return {
    id: message.id,
    role: message.role,
    content: message.content,
    timestamp: formatTimestamp(message.timestamp),
    status: 'sent',
  }
}

export async function fetchChat(): Promise<ChatState> {
  const response = await apiRequest<ChatApiResponse>('/chat')

  return {
    sessionId: response.session_id,
    agent: response.agent,
    messages: response.messages.map(normalizeMessage),
    sessionSummary: response.session_summary || undefined,
  }
}

export async function sendMessage(content: string): Promise<void> {
  await apiRequest('/chat', {
    method: 'POST',
    body: JSON.stringify({ message: { content } }),
  })
}
