import { render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import App from './App'

describe('App', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.restoreAllMocks()
  })

  afterEach(() => {
    localStorage.clear()
  })

  it('renders the development login page when unauthenticated', () => {
    render(<App />)

    expect(screen.getByText('DailyWerk')).toBeInTheDocument()
    expect(screen.getByText('Sign In (Dev)')).toBeInTheDocument()
    expect(
      screen.getByDisplayValue('sascha@dailywerk.com'),
    ).toBeInTheDocument()
  })

  it('renders the health dashboard when a session is stored', async () => {
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
          status: 'ok',
          timestamp: '2026-03-30T10:00:00Z',
          version: '8.1.3',
          ruby: '4.0.2',
        }),
      }),
    )

    render(<App />)

    expect(screen.getByText('Personal')).toBeInTheDocument()

    await waitFor(() => {
      expect(screen.getByText('ok')).toBeInTheDocument()
    })
  })
})
