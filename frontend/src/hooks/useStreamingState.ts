import {
  type Dispatch,
  type SetStateAction,
  useCallback,
  useRef,
  useState,
} from 'react'
import type { Message } from '../types/chat'

export interface CableEvent {
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

export interface UseStreamingStateReturn {
  messages: Message[]
  streamingContent: string
  streamingMessageId: string | null
  isStreaming: boolean
  activeAgent: string | null
  setActiveAgent: (agentName: string | null) => void
  setMessages: Dispatch<SetStateAction<Message[]>>
  appendAssistantError: (content: string) => void
  appendUserMessage: (content: string) => void
  handleCableEvent: (event: CableEvent) => void
  resetStreamingState: () => void
}

export function useStreamingState(
  defaultAgentName: string | null,
): UseStreamingStateReturn {
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

  const appendMessage = useCallback((message: Message) => {
    setMessages((prev) => [...prev, message])
  }, [])

  const appendAssistantError = useCallback(
    (content: string) => {
      appendMessage({
        id: crypto.randomUUID(),
        role: 'assistant',
        content,
        agentName: activeAgentRef.current || undefined,
        timestamp: timestampLabel(),
        status: 'error',
      })
    },
    [appendMessage],
  )

  const appendUserMessage = useCallback(
    (content: string) => {
      appendMessage({
        id: crypto.randomUUID(),
        role: 'user',
        content,
        timestamp: timestampLabel(),
        status: 'sent',
      })
    },
    [appendMessage],
  )

  const handleCableEvent = useCallback(
    (event: CableEvent) => {
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
            appendMessage({
              id: messageId,
              role: 'assistant',
              content: finalContent,
              agentName: activeAgentRef.current || undefined,
              timestamp: timestampLabel(),
              status: 'sent',
              thinkingContent: thinkingRef.current || undefined,
            })
          }

          resetStreamingState()
          break
        }

        case 'error': {
          const errorMsg = (event.message as string) || 'An error occurred'
          appendAssistantError(errorMsg)
          resetStreamingState()
          break
        }

        case 'agent_handoff': {
          const newAgent = event.agent as string
          syncActiveAgent(newAgent)
          appendMessage({
            id: crypto.randomUUID(),
            role: 'system',
            content: `Handed off to ${newAgent}`,
            timestamp: timestampLabel(),
            status: 'sent',
          })
          break
        }

        case 'thinking_start': {
          thinkingRef.current = ''
          break
        }

        case 'thinking_end':
        case 'tool_call':
          break
      }
    },
    [
      appendAssistantError,
      appendMessage,
      resetStreamingState,
      syncActiveAgent,
    ],
  )

  return {
    messages,
    streamingContent,
    streamingMessageId,
    isStreaming,
    activeAgent,
    setActiveAgent: syncActiveAgent,
    setMessages,
    appendAssistantError,
    appendUserMessage,
    handleCableEvent,
    resetStreamingState,
  }
}

function timestampLabel(): string {
  return new Date().toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
  })
}
