import { act, renderHook } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { useStreamingState } from './useStreamingState'

describe('useStreamingState', () => {
  it('reconstructs a streamed assistant message and clears transient state', () => {
    const { result } = renderHook(() => useStreamingState('DailyWerk'))

    act(() => {
      result.current.handleCableEvent({
        type: 'token',
        delta: 'Hel',
        message_id: 'assistant-1',
      })
      result.current.handleCableEvent({
        type: 'token',
        delta: 'lo',
      })
      result.current.handleCableEvent({
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
    expect(result.current.streamingMessageId).toBeNull()
    expect(result.current.isStreaming).toBe(false)
  })

  it('tracks handoffs and surfaces cable errors as assistant messages', () => {
    const { result } = renderHook(() => useStreamingState('DailyWerk'))

    act(() => {
      result.current.handleCableEvent({
        type: 'agent_handoff',
        agent: 'Research',
      })
      result.current.handleCableEvent({
        type: 'error',
        message: 'Stream failed',
      })
    })

    expect(result.current.activeAgent).toBe('Research')
    expect(result.current.messages).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          role: 'system',
          content: 'Handed off to Research',
        }),
        expect.objectContaining({
          role: 'assistant',
          content: 'Stream failed',
          status: 'error',
          agentName: 'Research',
        }),
      ]),
    )
  })
})
