import { getToken } from '../contexts/tokenStore'
import { refreshToken } from './authApi'

const API_BASE = '/api/v1'

let refreshPromise: Promise<string | null> | null = null

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
        window.dispatchEvent(new Event('auth:logout'))
        throw new Error(`HTTP ${retryResponse.status}`)
      }

      if (retryResponse.status === 204) return undefined as T
      return retryResponse.json() as Promise<T>
    }

    window.dispatchEvent(new Event('auth:logout'))
    throw new Error('HTTP 401')
  }

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`)
  }

  if (response.status === 204) {
    return undefined as T
  }

  return response.json() as Promise<T>
}

async function attemptRefresh(): Promise<string | null> {
  if (refreshPromise) return refreshPromise

  refreshPromise = refreshToken()
    .then((res) => res.access_token)
    .catch(() => null)
    .finally(() => {
      refreshPromise = null
    })

  return refreshPromise
}
