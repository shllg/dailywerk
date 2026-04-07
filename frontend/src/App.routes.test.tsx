import { render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import App from './App'

const authState = vi.hoisted(() => ({
  isAuthenticated: true,
  isLoading: false,
  logout: vi.fn(),
  setSession: vi.fn(),
  token: 'jwt-token',
  user: {
    id: 'user-1',
    email: 'owner@dailywerk.com',
    name: 'Owner',
  },
  workspace: {
    id: 'workspace-1',
    name: 'Personal',
  },
}))

vi.mock('./contexts/AuthContext', () => ({
  AuthProvider: ({ children }: { children: React.ReactNode }) => children,
}))

vi.mock('./hooks/useAuth', () => ({
  useAuth: () => authState,
}))

vi.mock('./components/settings/SettingsDrawer', () => ({
  SettingsDrawer: () => null,
}))

vi.mock('./pages/ChatPage', () => ({
  ChatPage: () => <div>Mock Chat Page</div>,
}))
vi.mock('./pages/AgentsPage', () => ({
  AgentsPage: () => <div>Mock Agents Page</div>,
}))
vi.mock('./pages/GatewaysPage', () => ({
  GatewaysPage: () => <div>Mock Gateways Page</div>,
}))
vi.mock('./pages/InboxPage', () => ({
  InboxPage: () => <div>Mock Inbox Page</div>,
}))
vi.mock('./pages/MemoryPage', () => ({
  MemoryPage: () => <div>Mock Memory Page</div>,
}))
vi.mock('./pages/VaultPage', () => ({
  VaultPage: () => <div>Mock Vault Page</div>,
}))
vi.mock('./pages/BillingPage', () => ({
  BillingPage: () => <div>Mock Billing Page</div>,
}))
vi.mock('./pages/IntegrationsPage', () => ({
  IntegrationsPage: () => <div>Mock Integrations Page</div>,
}))
vi.mock('./pages/ProfilePage', () => ({
  ProfilePage: () => <div>Mock Profile Page</div>,
}))
vi.mock('./pages/SettingsPage', () => ({
  SettingsPage: () => <div>Mock Settings Page</div>,
}))
vi.mock('./pages/AuthCallbackPage', () => ({
  AuthCallbackPage: () => <div>Mock Auth Callback</div>,
}))

describe('App routes', () => {
  beforeEach(() => {
    authState.isAuthenticated = true
    authState.isLoading = false
    authState.token = 'jwt-token'
    authState.user = {
      id: 'user-1',
      email: 'owner@dailywerk.com',
      name: 'Owner',
    }
    authState.workspace = {
      id: 'workspace-1',
      name: 'Personal',
    }
  })

  it('renders the authenticated shell and route metadata for routed pages', () => {
    window.history.pushState({}, '', '/settings')

    render(<App />)

    expect(screen.getByRole('heading', { name: 'Settings' })).toBeInTheDocument()
    expect(screen.getByText('Personal')).toBeInTheDocument()
    expect(screen.getByText('Mock Settings Page')).toBeInTheDocument()
  })

  it('redirects the root route to chat', async () => {
    window.history.pushState({}, '', '/')

    render(<App />)

    await waitFor(() => {
      expect(screen.getByText('Mock Chat Page')).toBeInTheDocument()
    })
    expect(screen.getByRole('heading', { name: 'Chat' })).toBeInTheDocument()
  })

  it('renders the auth callback route outside the app shell', () => {
    window.history.pushState({}, '', '/auth/callback')

    render(<App />)

    expect(screen.getByText('Mock Auth Callback')).toBeInTheDocument()
    expect(screen.queryByText('Workspace owner')).not.toBeInTheDocument()
  })
})
