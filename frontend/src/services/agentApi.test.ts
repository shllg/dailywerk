import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  fetchAgentConfig,
  resetAgentConfig,
  updateAgentConfig,
} from './agentApi'

// Mock the auth module to provide a token
vi.mock('../contexts/AuthContext', () => ({
  getToken: () => 'test-token',
}))

// Mock authApi to prevent real refresh calls
vi.mock('./authApi', () => ({
  refreshToken: () => Promise.reject(new Error('no refresh in test')),
}))

describe('agentApi', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('fetches the agent config payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        agent: {
          id: 'agent-1',
          slug: 'main',
          name: 'DailyWerk',
          model_id: 'gpt-5.4',
          provider: null,
          temperature: 0.7,
          instructions: 'Be concise.',
          soul: null,
          identity: {},
          params: {},
          thinking: {},
          is_default: true,
          active: true,
        },
        defaults: {
          name: 'DailyWerk',
          model_id: 'gpt-5.4',
          provider: null,
          temperature: 0.7,
          instructions: 'Be concise.',
          soul: null,
          identity: {},
          params: {},
          thinking: {},
        },
      }),
    })
    vi.stubGlobal('fetch', fetchMock)

    const response = await fetchAgentConfig('agent-1')
    const options = fetchMock.mock.calls[0][1] as RequestInit

    expect(fetchMock.mock.calls[0][0]).toBe('/api/v1/agents/agent-1')
    expect((options.headers as Headers).get('Authorization')).toBe(
      'Bearer test-token',
    )
    expect(response.agent.id).toBe('agent-1')
    expect(response.defaults.model_id).toBe('gpt-5.4')
  })

  it('patches the editable agent fields', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        agent: { id: 'agent-1' },
        defaults: {},
      }),
    })
    vi.stubGlobal('fetch', fetchMock)

    await updateAgentConfig('agent-1', {
      name: 'Operations',
      model_id: 'claude-3-7-sonnet',
    })

    const [url, options] = fetchMock.mock.calls[0] as [string, RequestInit]

    expect(url).toBe('/api/v1/agents/agent-1')
    expect(options.method).toBe('PATCH')
    expect(options.body).toBe(
      JSON.stringify({
        agent: {
          name: 'Operations',
          model_id: 'claude-3-7-sonnet',
        },
      }),
    )
  })

  it('posts to the reset endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        agent: { id: 'agent-1' },
        defaults: {},
      }),
    })
    vi.stubGlobal('fetch', fetchMock)

    await resetAgentConfig('agent-1')

    const [url, options] = fetchMock.mock.calls[0] as [string, RequestInit]

    expect(url).toBe('/api/v1/agents/agent-1/reset')
    expect(options.method).toBe('POST')
  })
})
