import {
  type Dispatch,
  type SetStateAction,
  useCallback,
  useEffect,
  useRef,
  useState,
} from 'react'
import type { Message } from '../types/chat'
import { createAuthenticatedConsumer } from '../services/cable'
import { sendMessage as sendChatMessage } from '../services/chatApi'

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
  setActiveAgent: (agentName: string | null) => void
  setMessages: Dispatch<SetStateAction<Message[]>>
}

export function useActionCableChat(
  sessionId: string | null,
  token: string | null,
  defaultAgentName: string | null,
): UseActionCableChatReturn {
  const [messages, setMessages] = useState<Message[]>([])
  const [streamingContent, setStreamingContent] = useState('')
  const [streamingMessageId, setStreamingMessageId] = useState<string | null>(
    null,
  )
  const [isStreaming, setIsStreaming] = useState(false)
  const [activeAgent, setActiveAgent] = useState<string | null>(
    defaultAgentName,
  )
  const streamingContentRef = useRef('')
  const streamingMessageIdRef = useRef<string | null>(null)
  const activeAgentRef = useRef<string | null>(defaultAgentName)
  const thinkingRef = useRef('')

  const syncActiveAgent = useCallback((agentName: string | null) => {
    activeAgentRef.current = agentName
    setActiveAgent(agentName)
  }, [])

  const resetStreamingState = useCallback(() => {
    setStreamingContent('')
    setStreamingMessageId(null)
    setIsStreaming(false)
    streamingContentRef.current = ''
    streamingMessageIdRef.current = null
    thinkingRef.current = ''
  }, [])

  useEffect(() => {
    if (!sessionId || !token) return

    const consumer = createAuthenticatedConsumer(token)

    const subscription = consumer.subscriptions.create(
      { channel: 'SessionChannel', session_id: sessionId },
      {
        disconnected() {
          resetStreamingState()
        },
        received(event: CableEvent) {
          switch (event.type) {
            case 'token': {
              const delta = typeof event.delta === 'string' ? event.delta : ''
              if (!delta) {
                break
              }

              const messageId =
                (event.message_id as string) ||
                streamingMessageIdRef.current ||
                crypto.randomUUID()

              const nextContent = streamingContentRef.current + delta
              streamingMessageIdRef.current = messageId
              streamingContentRef.current = nextContent
              setStreamingMessageId(messageId)
              setStreamingContent(nextContent)
              setIsStreaming(true)
              break
            }

            case 'complete': {
              const finalContent =
                (event.content as string) || streamingContentRef.current
              const messageId =
                (event.message_id as string) ||
                streamingMessageIdRef.current ||
                crypto.randomUUID()

              if (finalContent) {
                setMessages((prev) => [
                  ...prev,
                  {
                    id: messageId,
                    role: 'assistant',
                    content: finalContent,
                    agentName: activeAgentRef.current || undefined,
                    timestamp: new Date().toLocaleTimeString([], {
                      hour: '2-digit',
                      minute: '2-digit',
                    }),
                    status: 'sent',
                    thinkingContent: thinkingRef.current || undefined,
                  },
                ])
              }

              resetStreamingState()
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
                  agentName: activeAgentRef.current || undefined,
                  timestamp: new Date().toLocaleTimeString([], {
                    hour: '2-digit',
                    minute: '2-digit',
                  }),
                  status: 'error',
                },
              ])
              resetStreamingState()
              break
            }

            case 'agent_handoff': {
              const newAgent = event.agent as string
              syncActiveAgent(newAgent)
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
      consumer.disconnect()
    }
  }, [resetStreamingState, sessionId, syncActiveAgent, token])

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

      void sendChatMessage(content).catch(() => {
        setMessages((prev) => [
          ...prev,
          {
            id: crypto.randomUUID(),
            role: 'assistant',
            content: 'Failed to send message. Please try again.',
            agentName: activeAgentRef.current || undefined,
            timestamp: new Date().toLocaleTimeString([], {
              hour: '2-digit',
              minute: '2-digit',
            }),
            status: 'error',
          },
        ])
      })
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
    setActiveAgent: syncActiveAgent,
    setMessages,
  }
}
