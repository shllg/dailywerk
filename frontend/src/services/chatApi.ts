import type { Message, Session } from '../types/chat'

const API_BASE = '/api/v1'

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return res.json() as Promise<T>
}

export function fetchSessions(): Promise<Session[]> {
  return request('/chat/sessions')
}

export function fetchMessages(sessionId: string): Promise<Message[]> {
  return request(`/chat/sessions/${sessionId}/messages`)
}

export function createSession(): Promise<Session> {
  return request('/chat/sessions', { method: 'POST' })
}

export function sendMessage(
  sessionId: string,
  content: string,
): Promise<Message> {
  return request(`/chat/sessions/${sessionId}/messages`, {
    method: 'POST',
    body: JSON.stringify({ message: { content } }),
  })
}
