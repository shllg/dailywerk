import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getMe, refreshToken } from './authApi'

describe('authApi', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('sends X-Requested-With when restoring the session cookie', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        access_token: 'jwt',
        user: { id: 'user-1', email: 'sascha@dailywerk.com', name: 'Sascha' },
        workspace: { id: 'workspace-1', name: 'Personal' },
      }),
    })
    vi.stubGlobal('fetch', fetchMock)

    await getMe()

    const [url, options] = fetchMock.mock.calls[0] as [string, RequestInit]
    const headers = new Headers(options.headers)

    expect(url).toBe('/api/v1/auth/me')
    expect(options.credentials).toBe('include')
    expect(headers.get('X-Requested-With')).toBe('XMLHttpRequest')
  })

  it('sends X-Requested-With when refreshing the session cookie', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ access_token: 'jwt' }),
    })
    vi.stubGlobal('fetch', fetchMock)

    await refreshToken()

    const [url, options] = fetchMock.mock.calls[0] as [string, RequestInit]
    const headers = new Headers(options.headers)

    expect(url).toBe('/api/v1/auth/refresh')
    expect(options.method).toBe('POST')
    expect(options.credentials).toBe('include')
    expect(headers.get('X-Requested-With')).toBe('XMLHttpRequest')
  })
})
