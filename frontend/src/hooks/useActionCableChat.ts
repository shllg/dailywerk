import { type Dispatch, type SetStateAction, useCallback } from 'react'
import type { Message } from '../types/chat'
import { sendMessage as sendChatMessage } from '../services/chatApi'
import { useCableSubscription } from './useCableSubscription'
import { useStreamingState } from './useStreamingState'

export interface UseActionCableChatReturn {
  messages: Message[]
  streamingContent: string
  streamingMessageId: string | null
  isStreaming: boolean
  activeAgent: string | null
  sendMessage: (content: string) => void
  setActiveAgent: (agentName: string | null) => void
  setMessages: Dispatch<SetStateAction<Message[]>>
}

export function useActionCableChat(
  sessionId: string | null,
  token: string | null,
  defaultAgentName: string | null,
): UseActionCableChatReturn {
  const {
    messages,
    streamingContent,
    streamingMessageId,
    isStreaming,
    activeAgent,
    setActiveAgent,
    setMessages,
    appendAssistantError,
    appendUserMessage,
    handleCableEvent,
    resetStreamingState,
  } = useStreamingState(defaultAgentName)

  const onTicketError = useCallback(() => {
    appendAssistantError(
      'Failed to connect to live updates. Please refresh and try again.',
    )
    resetStreamingState()
  }, [appendAssistantError, resetStreamingState])

  useCableSubscription({
    sessionId,
    token,
    onDisconnected: resetStreamingState,
    onReceived: handleCableEvent,
    onTicketError,
  })

  const sendMessage = useCallback(
    (content: string) => {
      if (!sessionId) return

      appendUserMessage(content)

      void sendChatMessage(content).catch(() => {
        appendAssistantError('Failed to send message. Please try again.')
      })
    },
    [appendAssistantError, appendUserMessage, sessionId],
  )

  return {
    messages,
    streamingContent,
    streamingMessageId,
    isStreaming,
    activeAgent,
    sendMessage,
    setActiveAgent,
    setMessages,
  }
}
