import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as chatApi from '../services/chatApi'
import { useActionCableChat } from './useActionCableChat'

const cableState = vi.hoisted(() => ({
  disconnected: undefined as (() => void) | undefined,
  received: undefined as ((event: unknown) => void) | undefined,
  disconnect: vi.fn(),
  unsubscribe: vi.fn(),
}))

vi.mock('../services/authApi', () => ({
  getWebsocketTicket: () => Promise.resolve({ ticket: 'test-ticket' }),
}))

vi.mock('../services/cable', () => ({
  createAuthenticatedConsumer: () => ({
    disconnect: cableState.disconnect,
    subscriptions: {
      create: (
        _channel: unknown,
        callbacks: {
          disconnected?(): void
          received(data: unknown): void
        },
      ) => {
        cableState.disconnected = callbacks.disconnected
        cableState.received = callbacks.received

        return {
          unsubscribe: cableState.unsubscribe,
        }
      },
    },
  }),
}))

vi.mock('../services/chatApi', async () => {
  const actual = await vi.importActual<typeof import('../services/chatApi')>(
    '../services/chatApi',
  )

  return {
    ...actual,
    sendMessage: vi.fn(),
  }
})

describe('useActionCableChat', () => {
  beforeEach(() => {
    cableState.received = undefined
    cableState.disconnected = undefined
    cableState.disconnect.mockReset()
    cableState.unsubscribe.mockReset()
    vi.mocked(chatApi.sendMessage).mockReset()
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('reconstructs the final assistant message from streamed tokens', async () => {
    const { result, unmount } = renderHook(() =>
      useActionCableChat('session-1', 'token-1', 'DailyWerk'),
    )

    // Wait for the async ticket exchange and subscription setup
    await waitFor(() => {
      expect(cableState.received).toBeTypeOf('function')
    })

    act(() => {
      cableState.received?.({
        type: 'token',
        delta: 'Hel',
        message_id: 'assistant-1',
      })
      cableState.received?.({
        type: 'token',
        delta: 'lo',
      })
      cableState.received?.({
        type: 'complete',
        message_id: 'assistant-1',
      })
    })

    expect(result.current.messages.at(-1)).toMatchObject({
      id: 'assistant-1',
      role: 'assistant',
      content: 'Hello',
      agentName: 'DailyWerk',
      status: 'sent',
    })
    expect(result.current.streamingContent).toBe('')

    unmount()

    expect(cableState.disconnect).toHaveBeenCalled()
  })

  it('sends user messages through the REST chat API', () => {
    vi.mocked(chatApi.sendMessage).mockResolvedValue(undefined)

    const { result } = renderHook(() =>
      useActionCableChat('session-1', 'token-1', 'DailyWerk'),
    )

    act(() => {
      result.current.sendMessage('Ping')
    })

    expect(vi.mocked(chatApi.sendMessage)).toHaveBeenCalledWith('Ping')
    expect(result.current.messages.at(-1)).toMatchObject({
      role: 'user',
      content: 'Ping',
      status: 'sent',
    })
  })
})
