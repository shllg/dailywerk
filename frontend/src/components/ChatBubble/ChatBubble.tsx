import type { ReactNode } from 'react'

export interface ChatBubbleProps {
  role: 'user' | 'assistant' | 'system'
  children: ReactNode
  agentName?: string
  timestamp?: string
  isStreaming?: boolean
}

export function ChatBubble({
  role,
  children,
  agentName,
  timestamp,
  isStreaming = false,
}: ChatBubbleProps) {
  const isUser = role === 'user'
  const isSystem = role === 'system'

  return (
    <div
      className={`flex ${isUser ? 'justify-end' : 'justify-start'} ${isSystem ? 'justify-center' : ''}`}
    >
      <div
        className={`max-w-[80%] rounded-2xl px-4 py-3 ${
          isUser
            ? 'bg-blue-600 text-white'
            : isSystem
              ? 'bg-gray-800/50 text-gray-400 text-sm italic max-w-[90%]'
              : 'bg-gray-800 text-gray-100'
        }`}
      >
        {!isUser && !isSystem && agentName && (
          <div className="text-xs font-medium text-gray-400 mb-1">
            {agentName}
          </div>
        )}
        <div className="text-sm leading-relaxed">{children}</div>
        <div className="flex items-center justify-end gap-2 mt-1">
          {isStreaming && (
            <span className="inline-block w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
          )}
          {timestamp && (
            <time className="text-xs text-gray-500">{timestamp}</time>
          )}
        </div>
      </div>
    </div>
  )
}
