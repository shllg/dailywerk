import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../contexts/tokenStore', () => ({
  getToken: vi.fn(() => 'stale-token'),
}))

vi.mock('./authApi', () => ({
  refreshToken: vi.fn(),
}))

function mockJsonResponse(status: number, body?: unknown) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  }
}

describe('apiRequest', () => {
  beforeEach(() => {
    vi.resetModules()
    vi.clearAllMocks()
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('deduplicates refresh and retries concurrent 401 responses once', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(mockJsonResponse(401))
      .mockResolvedValueOnce(mockJsonResponse(401))
      .mockResolvedValueOnce(mockJsonResponse(200, { ok: true }))
      .mockResolvedValueOnce(mockJsonResponse(200, { ok: true }))
    vi.stubGlobal('fetch', fetchMock)

    const authApi = await import('./authApi')
    vi.mocked(authApi.refreshToken).mockResolvedValue({
      access_token: 'fresh-token',
    })
    const { apiRequest } = await import('./api')

    const results = await Promise.all([
      apiRequest<{ ok: boolean }>('/chat'),
      apiRequest<{ ok: boolean }>('/chat'),
    ])

    expect(authApi.refreshToken).toHaveBeenCalledTimes(1)
    expect(results).toEqual([{ ok: true }, { ok: true }])
    expect(fetchMock).toHaveBeenCalledTimes(4)
  })

  it('dispatches logout only once when concurrent retries still fail', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(mockJsonResponse(401))
      .mockResolvedValueOnce(mockJsonResponse(401))
      .mockResolvedValueOnce(mockJsonResponse(401))
      .mockResolvedValueOnce(mockJsonResponse(401))
    vi.stubGlobal('fetch', fetchMock)

    const dispatchSpy = vi.spyOn(window, 'dispatchEvent')
    const authApi = await import('./authApi')
    vi.mocked(authApi.refreshToken).mockResolvedValue({
      access_token: 'fresh-token',
    })
    const { apiRequest } = await import('./api')

    await Promise.allSettled([
      apiRequest('/chat'),
      apiRequest('/chat'),
    ])

    expect(authApi.refreshToken).toHaveBeenCalledTimes(1)
    expect(
      dispatchSpy.mock.calls.filter(
        ([event]) => (event as Event).type === 'auth:logout',
      ),
    ).toHaveLength(1)
  })
})
