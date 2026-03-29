import type { Message, Session } from '../types/chat'
import { apiRequest } from './api'

export function fetchSessions(): Promise<Session[]> {
  return apiRequest('/chat/sessions')
}

export function fetchMessages(sessionId: string): Promise<Message[]> {
  return apiRequest(`/chat/sessions/${sessionId}/messages`)
}

export function createSession(): Promise<Session> {
  return apiRequest('/chat/sessions', { method: 'POST' })
}

export function sendMessage(
  sessionId: string,
  content: string,
): Promise<Message> {
  return apiRequest(`/chat/sessions/${sessionId}/messages`, {
    method: 'POST',
    body: JSON.stringify({ message: { content } }),
  })
}
