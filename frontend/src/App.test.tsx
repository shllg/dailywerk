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

describe('App', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.restoreAllMocks()
  })

  afterEach(() => {
    localStorage.clear()
  })

  it('renders the development login page when unauthenticated', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          build_ref: 'main',
          build_sha: 'abcdef1234567890',
        }),
      }),
    )

    render(<App />)

    expect(screen.getByText('DailyWerk')).toBeInTheDocument()
    expect(screen.getByText('Sign In (Dev)')).toBeInTheDocument()
    expect(
      screen.getByDisplayValue('sascha@dailywerk.com'),
    ).toBeInTheDocument()

    await waitFor(() => {
      expect(screen.getByText('Build main - abcdef1')).toBeInTheDocument()
    })
  })

  it('renders the single chat view when a session is stored', async () => {
    localStorage.setItem('auth_token', 'test-token')
    localStorage.setItem(
      'auth_user',
      JSON.stringify({
        id: 'user-1',
        email: 'sascha@dailywerk.com',
        name: 'Sascha',
      }),
    )
    localStorage.setItem(
      'auth_workspace',
      JSON.stringify({
        id: 'workspace-1',
        name: 'Personal',
      }),
    )

    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          session_id: 'session-1',
          agent: {
            id: 'agent-1',
            slug: 'main',
            name: 'DailyWerk',
          },
          messages: [
            {
              id: 'message-1',
              role: 'assistant',
              content: 'How can I help?',
              timestamp: '2026-03-30T10:00:00Z',
            },
          ],
        }),
      }),
    )

    render(<App />)

    expect(screen.getByText('Personal')).toBeInTheDocument()
    expect(screen.getByText('Gateways')).toBeInTheDocument()

    await waitFor(() => {
      expect(screen.getByText('How can I help?')).toBeInTheDocument()
    })
  })
})
