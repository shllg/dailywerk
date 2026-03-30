import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { SessionResponse } from '../types/auth'
import type { AuthUser, AuthWorkspace } from '../types/auth'
import { AuthContext } from './AuthContextValue'

const AUTH_TOKEN_KEY = 'auth_token'
const AUTH_USER_KEY = 'auth_user'
const AUTH_WORKSPACE_KEY = 'auth_workspace'

function readStoredJson<T>(key: string): T | null {
  const value = localStorage.getItem(key)
  if (!value) return null

  try {
    return JSON.parse(value) as T
  } catch {
    localStorage.removeItem(key)
    return null
  }
}

function clearStoredAuth() {
  localStorage.removeItem(AUTH_TOKEN_KEY)
  localStorage.removeItem(AUTH_USER_KEY)
  localStorage.removeItem(AUTH_WORKSPACE_KEY)
}

function persistSession(response: SessionResponse) {
  localStorage.setItem(AUTH_TOKEN_KEY, response.token)
  localStorage.setItem(AUTH_USER_KEY, JSON.stringify(response.user))
  localStorage.setItem(AUTH_WORKSPACE_KEY, JSON.stringify(response.workspace))
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [token, setToken] = useState<string | null>(() =>
    localStorage.getItem(AUTH_TOKEN_KEY),
  )
  const [user, setUser] = useState<AuthUser | null>(() =>
    readStoredJson<AuthUser>(AUTH_USER_KEY),
  )
  const [workspace, setWorkspace] = useState<AuthWorkspace | null>(() =>
    readStoredJson<AuthWorkspace>(AUTH_WORKSPACE_KEY),
  )

  const syncFromStorage = useCallback(() => {
    setToken(localStorage.getItem(AUTH_TOKEN_KEY))
    setUser(readStoredJson<AuthUser>(AUTH_USER_KEY))
    setWorkspace(readStoredJson<AuthWorkspace>(AUTH_WORKSPACE_KEY))
  }, [])

  const logout = useCallback(() => {
    clearStoredAuth()
    setToken(null)
    setUser(null)
    setWorkspace(null)
  }, [])

  useEffect(() => {
    const handleStorage = (event: StorageEvent) => {
      if (
        event.key &&
        ![AUTH_TOKEN_KEY, AUTH_USER_KEY, AUTH_WORKSPACE_KEY].includes(event.key)
      ) {
        return
      }

      syncFromStorage()
    }

    const handleLogout = () => {
      logout()
    }

    window.addEventListener('storage', handleStorage)
    window.addEventListener('auth:logout', handleLogout)

    return () => {
      window.removeEventListener('storage', handleStorage)
      window.removeEventListener('auth:logout', handleLogout)
    }
  }, [logout, syncFromStorage])

  // TODO: [WorkOS] Replace with a redirect to the WorkOS authorization URL.
  // The rest of this context (token storage, Bearer header, logout) stays identical.
  const login = useCallback(async (email: string) => {
    const response = await fetch('/api/v1/sessions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ session: { email } }),
    })

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`)
    }

    const session = (await response.json()) as SessionResponse

    persistSession(session)
    setToken(session.token)
    setUser(session.user)
    setWorkspace(session.workspace)
  }, [])

  const value = useMemo(
    () => ({
      user,
      workspace,
      token,
      isAuthenticated: Boolean(token && user && workspace),
      login,
      logout,
    }),
    [user, workspace, token, login, logout],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
