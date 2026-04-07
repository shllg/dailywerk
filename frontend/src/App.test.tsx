import { render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import App from './App'

vi.mock('./services/cable', () => ({
  createAuthenticatedConsumer: () => ({
    disconnect: vi.fn(),
    subscriptions: {
      create: () => ({
        unsubscribe: vi.fn(),
      }),
    },
  }),
}))

function mockFetch(overrides: Record<string, unknown> = {}) {
  return vi.fn().mockImplementation((url: string) => {
    // Auth provider check
    if (url.includes('/auth/provider')) {
      return Promise.resolve({
        ok: true,
        status: 200,
        json: async () => ({ provider: 'dev' }),
      })
    }

    // Session restore — unauthenticated by default
    if (url.includes('/auth/me')) {
      if (overrides.authenticated) {
        return Promise.resolve({
          ok: true,
          status: 200,
          json: async () => ({
            access_token: 'test-jwt-token',
            user: {
              id: 'user-1',
              email: 'sascha@dailywerk.com',
              name: 'Sascha',
            },
            workspace: { id: 'workspace-1', name: 'Personal' },
          }),
        })
      }
      return Promise.resolve({ ok: false, status: 401 })
    }

    // Health check
    if (url.includes('/health')) {
      return Promise.resolve({
        ok: true,
        status: 200,
        json: async () => ({
          build_sha: 'abcdef1234567890',
        }),
      })
    }

    // Chat/agent requests
    return Promise.resolve({
      ok: true,
      status: 200,
      json: async () => ({
        session_id: 'session-1',
        agent: { id: 'agent-1', slug: 'main', name: 'DailyWerk' },
        messages: [
          {
            id: 'message-1',
            role: 'assistant',
            content: 'How can I help?',
            timestamp: '2026-03-30T10:00:00Z',
          },
        ],
      }),
    })
  })
}

describe('App', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('renders the development login page when unauthenticated', async () => {
    vi.stubGlobal('fetch', mockFetch())

    render(<App />)

    await waitFor(() => {
      expect(screen.getByText('DailyWerk')).toBeInTheDocument()
    })

    await waitFor(() => {
      expect(screen.getByText('Sign In (Dev)')).toBeInTheDocument()
    })

    expect(
      screen.getByDisplayValue('sascha@dailywerk.com'),
    ).toBeInTheDocument()

    await waitFor(() => {
      expect(screen.getByText('Build abcdef1')).toBeInTheDocument()
    })
  })

  it('renders the single chat view when session is restored', async () => {
    vi.stubGlobal('fetch', mockFetch({ authenticated: true }))

    render(<App />)

    await waitFor(() => {
      expect(screen.getByText('Personal')).toBeInTheDocument()
    })

    expect(screen.getByText('Gateways')).toBeInTheDocument()

    await waitFor(() => {
      expect(screen.getByText('How can I help?')).toBeInTheDocument()
    })
  })
})
