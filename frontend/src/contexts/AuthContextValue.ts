import { createContext } from 'react'
import type { AuthUser, AuthWorkspace } from '../types/auth'

export interface AuthContextValue {
  user: AuthUser | null
  workspace: AuthWorkspace | null
  token: string | null
  isAuthenticated: boolean
  login: (email: string) => Promise<void>
  logout: () => void
}

export const AuthContext = createContext<AuthContextValue | undefined>(undefined)
