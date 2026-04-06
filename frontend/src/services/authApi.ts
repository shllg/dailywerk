import type {
  AuthLoginResponse,
  AuthLogoutResponse,
  AuthMeResponse,
  AuthProviderResponse,
  AuthRefreshResponse,
  WebsocketTicketResponse,
} from '../types/auth'

const API_BASE = '/api/v1'

async function authFetch<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, {
    ...options,
    credentials: 'include',
  })

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`)
  }

  return response.json() as Promise<T>
}

export function getAuthProvider(): Promise<AuthProviderResponse> {
  return authFetch('/auth/provider')
}

export function getLoginUrl(): Promise<AuthLoginResponse> {
  return authFetch('/auth/login')
}

export function getMe(): Promise<AuthMeResponse> {
  return authFetch('/auth/me')
}

export function refreshToken(): Promise<AuthRefreshResponse> {
  return authFetch('/auth/refresh', {
    method: 'POST',
    headers: { 'X-Requested-With': 'XMLHttpRequest' },
  })
}

export function postLogout(token: string): Promise<AuthLogoutResponse> {
  return authFetch('/auth/logout', {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${token}` },
  })
}

export function getWebsocketTicket(
  token: string,
): Promise<WebsocketTicketResponse> {
  return authFetch('/auth/websocket_ticket', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
  })
}
