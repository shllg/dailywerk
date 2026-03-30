import { useEffect, useState } from 'react'
import { useActionCableChat } from '../../hooks/useActionCableChat'
import { useAutoScroll } from '../../hooks/useAutoScroll'
import { fetchChat } from '../../services/chatApi'
import { MessageBubble } from './MessageBubble'
import { MessageInput } from './MessageInput'
import { TypingIndicator } from './TypingIndicator'

export interface ChatContainerProps {
  token: string
}

export function ChatContainer({ token }: ChatContainerProps) {
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [agentName, setAgentName] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [reloadCount, setReloadCount] = useState(0)
  const {
    messages,
    streamingContent,
    streamingMessageId,
    isStreaming,
    activeAgent,
    sendMessage,
    setMessages,
  } = useActionCableChat(sessionId, token, agentName)
  const { ref, scrollIfAtBottom, scrollToBottom, isAtBottom } =
    useAutoScroll<HTMLDivElement>()

  useEffect(() => {
    let cancelled = false

    setIsLoading(true)
    fetchChat()
      .then((chat) => {
        if (cancelled) return

        setSessionId(chat.sessionId)
        setAgentName(chat.agent.name)
        setMessages(
          chat.messages.map((message) =>
            message.role === 'assistant'
              ? { ...message, agentName: chat.agent.name }
              : message,
          ),
        )
        setError(null)
      })
      .catch((err: Error) => {
        if (cancelled) return
        setSessionId(null)
        setAgentName(null)
        setMessages([])
        setError(err.message)
      })
      .finally(() => {
        if (!cancelled) {
          setIsLoading(false)
        }
      })

    return () => {
      cancelled = true
    }
  }, [reloadCount, setMessages, token])

  useEffect(() => {
    scrollIfAtBottom()
  }, [messages, streamingContent, scrollIfAtBottom])

  if (isLoading) {
    return (
      <div className="flex flex-1 items-center justify-center rounded-[32px] border border-white/10 bg-slate-950/70 px-6 py-12 text-slate-400 shadow-2xl shadow-slate-950/40">
        <p>Loading your conversation…</p>
      </div>
    )
  }

  if (error || !sessionId) {
    return (
      <div className="flex flex-1 items-center justify-center rounded-[32px] border border-red-500/20 bg-slate-950/70 px-6 py-12 shadow-2xl shadow-slate-950/40">
        <div className="max-w-sm text-center">
          <p className="text-base font-medium text-red-200">
            Chat failed to load
          </p>
          <p className="mt-2 text-sm text-slate-400">
            {error || 'The current chat session could not be resolved.'}
          </p>
          <button
            type="button"
            onClick={() => setReloadCount((count) => count + 1)}
            className="mt-5 rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm font-medium text-slate-200 transition hover:border-white/20 hover:bg-white/10"
          >
            Retry
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="flex h-full flex-1 flex-col overflow-hidden rounded-[32px] border border-white/10 bg-slate-950/70 shadow-2xl shadow-slate-950/40 backdrop-blur-xl">
      <div className="border-b border-white/10 px-5 py-4">
        <p className="text-sm font-medium text-slate-100">{agentName}</p>
        <p className="mt-1 text-xs uppercase tracking-[0.24em] text-slate-500">
          Continuous web session
        </p>
      </div>

      <div ref={ref} className="flex-1 overflow-y-auto px-4 py-5 sm:px-5">
        <div className="space-y-3">
          {messages.map((message) => (
            <MessageBubble key={message.id} message={message} />
          ))}

          {isStreaming && streamingContent && (
            <MessageBubble
              message={{
                id: streamingMessageId || 'streaming',
                role: 'assistant',
                content: streamingContent,
                agentName: activeAgent || agentName || undefined,
                timestamp: '',
                status: 'streaming',
              }}
            />
          )}

          {isStreaming && !streamingContent && (
            <TypingIndicator
              agentName={activeAgent || agentName || undefined}
            />
          )}
        </div>
      </div>

      {!isAtBottom && (
        <div className="flex justify-center py-2">
          <button
            onClick={scrollToBottom}
            className="text-xs text-gray-400 bg-gray-800 px-3 py-1 rounded-full hover:text-gray-200 transition-colors"
          >
            Scroll to bottom
          </button>
        </div>
      )}

      <MessageInput
        onSend={sendMessage}
        disabled={isStreaming || !sessionId}
        placeholder="Ask DailyWerk anything..."
      />
    </div>
  )
}
