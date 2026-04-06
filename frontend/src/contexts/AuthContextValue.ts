import { createContext } from 'react'
import type { AuthUser, AuthWorkspace } from '../types/auth'

export interface AuthContextValue {
  user: AuthUser | null
  workspace: AuthWorkspace | null
  token: string | null
  isAuthenticated: boolean
  isLoading: boolean
  login: (email?: string) => Promise<void>
  logout: () => void
  setSession: (
    token: string,
    user: AuthUser,
    workspace: AuthWorkspace,
  ) => void
}

export const AuthContext = createContext<AuthContextValue | undefined>(undefined)
