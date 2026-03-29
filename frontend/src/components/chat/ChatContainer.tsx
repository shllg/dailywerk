import { useEffect } from 'react'
import { useActionCableChat } from '../../hooks/useActionCableChat'
import { useAutoScroll } from '../../hooks/useAutoScroll'
import { fetchMessages } from '../../services/chatApi'
import { MessageBubble } from './MessageBubble'
import { MessageInput } from './MessageInput'
import { TypingIndicator } from './TypingIndicator'

export interface ChatContainerProps {
  sessionId: string | null
}

export function ChatContainer({ sessionId }: ChatContainerProps) {
  const {
    messages,
    streamingContent,
    isStreaming,
    activeAgent,
    sendMessage,
    setMessages,
  } = useActionCableChat(sessionId)
  const { ref, scrollIfAtBottom, scrollToBottom, isAtBottom } =
    useAutoScroll<HTMLDivElement>()

  useEffect(() => {
    if (!sessionId) return
    fetchMessages(sessionId).then(setMessages).catch(console.error)
  }, [sessionId, setMessages])

  useEffect(() => {
    scrollIfAtBottom()
  }, [messages, streamingContent, scrollIfAtBottom])

  if (!sessionId) {
    return (
      <div className="flex-1 flex items-center justify-center text-gray-500">
        <p>Select a conversation or start a new one</p>
      </div>
    )
  }

  return (
    <div className="flex flex-col h-full">
      <div ref={ref} className="flex-1 overflow-y-auto p-4 space-y-3">
        {messages.map((message) => (
          <MessageBubble key={message.id} message={message} />
        ))}

        {isStreaming && streamingContent && (
          <MessageBubble
            message={{
              id: 'streaming',
              role: 'assistant',
              content: streamingContent,
              agentName: activeAgent || undefined,
              timestamp: '',
              status: 'streaming',
            }}
          />
        )}

        {isStreaming && !streamingContent && (
          <TypingIndicator agentName={activeAgent || undefined} />
        )}
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
        disabled={isStreaming}
        placeholder="Ask DailyWerk anything..."
      />
    </div>
  )
}
