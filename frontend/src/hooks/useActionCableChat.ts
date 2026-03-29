import { useCallback, useEffect, useRef, useState } from 'react'
import type { Message } from '../types/chat'
import consumer from '../services/cable'

interface CableEvent {
  type:
    | 'token'
    | 'complete'
    | 'error'
    | 'tool_call'
    | 'agent_handoff'
    | 'thinking_start'
    | 'thinking_end'
  [key: string]: unknown
}

export interface UseActionCableChatReturn {
  messages: Message[]
  streamingContent: string
  streamingMessageId: string | null
  isStreaming: boolean
  activeAgent: string | null
  sendMessage: (content: string) => void
  setMessages: React.Dispatch<React.SetStateAction<Message[]>>
}

export function useActionCableChat(
  sessionId: string | null,
): UseActionCableChatReturn {
  const [messages, setMessages] = useState<Message[]>([])
  const [streamingContent, setStreamingContent] = useState('')
  const [streamingMessageId, setStreamingMessageId] = useState<string | null>(
    null,
  )
  const [isStreaming, setIsStreaming] = useState(false)
  const [activeAgent, setActiveAgent] = useState<string | null>(null)
  const thinkingRef = useRef('')

  useEffect(() => {
    if (!sessionId) return

    const subscription = consumer.subscriptions.create(
      { channel: 'SessionChannel', session_id: sessionId },
      {
        received(event: CableEvent) {
          switch (event.type) {
            case 'token': {
              const delta = event.delta as string
              setStreamingContent((prev) => prev + delta)
              if (!streamingMessageId) {
                setStreamingMessageId(
                  (event.message_id as string) || crypto.randomUUID(),
                )
              }
              setIsStreaming(true)
              break
            }

            case 'complete': {
              const finalContent =
                (event.content as string) || streamingContent
              const messageId =
                (event.message_id as string) ||
                streamingMessageId ||
                crypto.randomUUID()

              setMessages((prev) => [
                ...prev,
                {
                  id: messageId,
                  role: 'assistant',
                  content: finalContent,
                  agentName: activeAgent || undefined,
                  timestamp: new Date().toLocaleTimeString([], {
                    hour: '2-digit',
                    minute: '2-digit',
                  }),
                  status: 'sent',
                  thinkingContent: thinkingRef.current || undefined,
                },
              ])
              setStreamingContent('')
              setStreamingMessageId(null)
              setIsStreaming(false)
              thinkingRef.current = ''
              break
            }

            case 'error': {
              const errorMsg = (event.message as string) || 'An error occurred'
              setMessages((prev) => [
                ...prev,
                {
                  id: crypto.randomUUID(),
                  role: 'assistant',
                  content: errorMsg,
                  agentName: activeAgent || undefined,
                  timestamp: new Date().toLocaleTimeString([], {
                    hour: '2-digit',
                    minute: '2-digit',
                  }),
                  status: 'error',
                },
              ])
              setStreamingContent('')
              setStreamingMessageId(null)
              setIsStreaming(false)
              thinkingRef.current = ''
              break
            }

            case 'agent_handoff': {
              const newAgent = event.agent as string
              setActiveAgent(newAgent)
              setMessages((prev) => [
                ...prev,
                {
                  id: crypto.randomUUID(),
                  role: 'system',
                  content: `Handed off to ${newAgent}`,
                  timestamp: new Date().toLocaleTimeString([], {
                    hour: '2-digit',
                    minute: '2-digit',
                  }),
                  status: 'sent',
                },
              ])
              break
            }

            case 'thinking_start': {
              thinkingRef.current = ''
              break
            }

            case 'thinking_end': {
              break
            }

            case 'tool_call': {
              // Tool call events are handled by the streaming message
              break
            }
          }
        },
      },
    )

    return () => {
      subscription.unsubscribe()
    }
    // streamingContent and streamingMessageId are refs in the closure,
    // we only want to re-subscribe when sessionId changes
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId])

  const sendMessage = useCallback(
    (content: string) => {
      if (!sessionId) return

      const userMessage: Message = {
        id: crypto.randomUUID(),
        role: 'user',
        content,
        timestamp: new Date().toLocaleTimeString([], {
          hour: '2-digit',
          minute: '2-digit',
        }),
        status: 'sent',
      }
      setMessages((prev) => [...prev, userMessage])

      consumer.subscriptions.subscriptions
        .find(
          (s: { identifier: string }) =>
            JSON.parse(s.identifier).channel === 'SessionChannel',
        )
        ?.perform('receive', { message: content })
    },
    [sessionId],
  )

  return {
    messages,
    streamingContent,
    streamingMessageId,
    isStreaming,
    activeAgent,
    sendMessage,
    setMessages,
  }
}
