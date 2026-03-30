import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchChat, sendMessage } from './chatApi'

describe('chatApi', () => {
  beforeEach(() => {
    localStorage.clear()
    localStorage.setItem('auth_token', 'test-token')
    vi.restoreAllMocks()
  })

  afterEach(() => {
    localStorage.clear()
  })

  it('maps the singleton chat payload into frontend chat state', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        session_id: 'session-1',
        agent: {
          slug: 'main',
          name: 'DailyWerk',
        },
        messages: [
          {
            id: 'message-1',
            role: 'assistant',
            content: 'Hello',
            timestamp: '2026-03-30T10:00:00Z',
          },
        ],
      }),
    })
    vi.stubGlobal('fetch', fetchMock)

    const chat = await fetchChat()
    const options = fetchMock.mock.calls[0][1] as RequestInit

    expect(fetchMock.mock.calls[0][0]).toBe('/api/v1/chat')
    expect((options.headers as Headers).get('Authorization')).toBe(
      'Bearer test-token',
    )
    expect(chat).toMatchObject({
      sessionId: 'session-1',
      agent: {
        slug: 'main',
        name: 'DailyWerk',
      },
    })
    expect(chat.messages[0]).toMatchObject({
      id: 'message-1',
      content: 'Hello',
      status: 'sent',
    })
  })

  it('posts messages to the singleton chat endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 202,
      json: async () => ({ session_id: 'session-1' }),
    })
    vi.stubGlobal('fetch', fetchMock)

    await sendMessage('Hello')

    const [url, options] = fetchMock.mock.calls[0] as [string, RequestInit]

    expect(url).toBe('/api/v1/chat')
    expect(options.method).toBe('POST')
    expect(options.body).toBe(JSON.stringify({ message: { content: 'Hello' } }))
    expect((options.headers as Headers).get('Authorization')).toBe(
      'Bearer test-token',
    )
  })
})
