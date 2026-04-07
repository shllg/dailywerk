import { getToken } from '../contexts/tokenStore'
import { refreshToken } from './authApi'

const API_BASE = '/api/v1'
const RECENT_REFRESH_WINDOW_MS = 1000

let refreshPromise: Promise<string | null> | null = null
let recentRefresh: { token: string | null; at: number } | null = null
let logoutDispatched = false

export async function apiRequest<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const headers = new Headers(options.headers)
  const token = getToken()

  if (token) headers.set('Authorization', `Bearer ${token}`)
  if (options.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json')
  }

  const response = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers,
  })

  if (response.status === 401) {
    // Attempt one refresh (deduplicated across concurrent requests)
    const newToken = await attemptRefresh()
    if (newToken) {
      // Retry with new token
      const retryHeaders = new Headers(options.headers)
      retryHeaders.set('Authorization', `Bearer ${newToken}`)
      if (options.body && !retryHeaders.has('Content-Type')) {
        retryHeaders.set('Content-Type', 'application/json')
      }

      const retryResponse = await fetch(`${API_BASE}${path}`, {
        ...options,
        headers: retryHeaders,
      })

      if (!retryResponse.ok) {
        dispatchLogoutOnce()
        throw new Error(`HTTP ${retryResponse.status}`)
      }

      clearLogoutState()
      return parseResponse<T>(retryResponse)
    }

    dispatchLogoutOnce()
    throw new Error('HTTP 401')
  }

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`)
  }

  clearLogoutState()
  return parseResponse<T>(response)
}

async function attemptRefresh(): Promise<string | null> {
  if (refreshPromise) return refreshPromise
  if (
    recentRefresh &&
    Date.now() - recentRefresh.at <= RECENT_REFRESH_WINDOW_MS
  ) {
    return recentRefresh.token
  }

  refreshPromise = refreshToken()
    .then((res) => {
      clearLogoutState()
      return res.access_token
    })
    .catch(() => null)
    .then((token) => {
      recentRefresh = { token, at: Date.now() }
      return token
    })
    .finally(() => {
      refreshPromise = null
    })

  return refreshPromise
}

function dispatchLogoutOnce() {
  if (logoutDispatched) return

  logoutDispatched = true
  window.dispatchEvent(new Event('auth:logout'))
}

function clearLogoutState() {
  logoutDispatched = false
}

async function parseResponse<T>(response: Response): Promise<T> {
  if (response.status === 204) {
    return undefined as T
  }

  return response.json() as Promise<T>
}
