const API_BASE = '/api/v1'

const AUTH_TOKEN_KEY = 'auth_token'
const AUTH_USER_KEY = 'auth_user'
const AUTH_WORKSPACE_KEY = 'auth_workspace'

function clearStoredAuth() {
  localStorage.removeItem(AUTH_TOKEN_KEY)
  localStorage.removeItem(AUTH_USER_KEY)
  localStorage.removeItem(AUTH_WORKSPACE_KEY)
}

export async function apiRequest<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const headers = new Headers(options.headers)
  const token = localStorage.getItem(AUTH_TOKEN_KEY)

  if (token) headers.set('Authorization', `Bearer ${token}`)
  if (options.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json')
  }

  const response = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers,
  })

  if (response.status === 401) {
    clearStoredAuth()
    window.dispatchEvent(new Event('auth:logout'))
  }

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`)
  }

  if (response.status === 204) {
    return undefined as T
  }

  return response.json() as Promise<T>
}
