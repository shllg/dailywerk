import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import type { AuthUser, AuthWorkspace } from '../types/auth'
import { AuthContext } from './AuthContextValue'
import { getAuthProvider, getLoginUrl, getMe, postLogout, refreshToken } from '../services/authApi'

// Module-level token ref for api.ts to access without React context
let currentToken: string | null = null

export function getToken(): string | null {
  return currentToken
}

function decodeJwtExp(token: string): number | null {
  try {
    const payload = token.split('.')[1]
    if (!payload) return null
    const decoded = JSON.parse(atob(payload))
    return typeof decoded.exp === 'number' ? decoded.exp : null
  } catch {
    return null
  }
}

const AUTH_CHANNEL = 'dailywerk_auth'

export function AuthProvider({ children }: { children: ReactNode }) {
  const [token, setTokenState] = useState<string | null>(null)
  const [user, setUser] = useState<AuthUser | null>(null)
  const [workspace, setWorkspace] = useState<AuthWorkspace | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const refreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const channelRef = useRef<BroadcastChannel | null>(null)

  const setToken = useCallback((t: string | null) => {
    currentToken = t
    setTokenState(t)
  }, [])

  const clearAuth = useCallback(() => {
    setToken(null)
    setUser(null)
    setWorkspace(null)
    if (refreshTimerRef.current) {
      clearTimeout(refreshTimerRef.current)
      refreshTimerRef.current = null
    }
  }, [setToken])

  // Schedule a token refresh 2 minutes before expiry
  const scheduleRefresh = useCallback(
    (jwt: string) => {
      if (refreshTimerRef.current) {
        clearTimeout(refreshTimerRef.current)
      }

      const exp = decodeJwtExp(jwt)
      if (!exp) return

      const msUntilRefresh = (exp - 120) * 1000 - Date.now()
      if (msUntilRefresh <= 0) {
        // Token already near expiry — refresh immediately
        void refreshToken()
          .then((res) => {
            setToken(res.access_token)
            scheduleRefresh(res.access_token)
            channelRef.current?.postMessage({
              type: 'token_refresh',
              access_token: res.access_token,
            })
          })
          .catch(() => clearAuth())
        return
      }

      refreshTimerRef.current = setTimeout(() => {
        void refreshToken()
          .then((res) => {
            setToken(res.access_token)
            scheduleRefresh(res.access_token)
            channelRef.current?.postMessage({
              type: 'token_refresh',
              access_token: res.access_token,
            })
          })
          .catch(() => clearAuth())
      }, msUntilRefresh)
    },
    [setToken, clearAuth],
  )

  const setSession = useCallback(
    (accessToken: string, authUser: AuthUser, authWorkspace: AuthWorkspace) => {
      setToken(accessToken)
      setUser(authUser)
      setWorkspace(authWorkspace)
      scheduleRefresh(accessToken)
    },
    [setToken, scheduleRefresh],
  )

  const logout = useCallback(() => {
    const t = currentToken
    clearAuth()
    channelRef.current?.postMessage({ type: 'logout' })

    if (t) {
      void postLogout(t)
        .then((res) => {
          if (res.logout_url) {
            window.location.href = res.logout_url
          }
        })
        .catch(() => {
          // Logout API failed — local state already cleared
        })
    }
  }, [clearAuth])

  const login = useCallback(
    async (email?: string) => {
      if (email) {
        // Dev mode — POST to sessions endpoint
        const response = await fetch('/api/v1/sessions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ session: { email } }),
        })

        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`)
        }

        const session = (await response.json()) as {
          token: string
          user: AuthUser
          workspace: AuthWorkspace
        }

        setSession(session.token, session.user, session.workspace)
        return
      }

      // WorkOS mode — redirect to authorization URL
      const cfg = await getAuthProvider()
      if (cfg.provider === 'dev') {
        throw new Error('Dev mode requires email parameter')
      }
      const { authorization_url } = await getLoginUrl()
      window.location.href = authorization_url
    },
    [setSession],
  )

  // Restore session from cookie on mount
  useEffect(() => {
    void getMe()
      .then((response) => {
        setSession(
          response.access_token,
          response.user,
          response.workspace,
        )
      })
      .catch(() => {
        // No valid session — stay logged out
      })
      .finally(() => {
        setIsLoading(false)
      })
  }, [setSession])

  // Cross-tab sync via BroadcastChannel
  useEffect(() => {
    if (typeof BroadcastChannel === 'undefined') return

    const channel = new BroadcastChannel(AUTH_CHANNEL)
    channelRef.current = channel

    channel.onmessage = (event: MessageEvent) => {
      const data = event.data as { type: string; access_token?: string }

      if (data.type === 'logout') {
        clearAuth()
      } else if (data.type === 'token_refresh' && data.access_token) {
        setToken(data.access_token)
        scheduleRefresh(data.access_token)
      }
    }

    return () => {
      channel.close()
      channelRef.current = null
    }
  }, [clearAuth, setToken, scheduleRefresh])

  // Clean up refresh timer on unmount
  useEffect(() => {
    return () => {
      if (refreshTimerRef.current) {
        clearTimeout(refreshTimerRef.current)
      }
    }
  }, [])

  const value = useMemo(
    () => ({
      user,
      workspace,
      token,
      isAuthenticated: Boolean(token && user && workspace),
      isLoading,
      login,
      logout,
      setSession,
    }),
    [user, workspace, token, isLoading, login, logout, setSession],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
