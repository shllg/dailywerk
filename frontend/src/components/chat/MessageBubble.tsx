import type { Message } from '../../types/chat'
import { MarkdownRenderer } from './MarkdownRenderer'
import { ThinkingBlock } from './ThinkingBlock'
import { ToolCallBlock } from './ToolCallBlock'

export interface MessageBubbleProps {
  message: Message
}

export function MessageBubble({ message }: MessageBubbleProps) {
  const isUser = message.role === 'user'
  const isSystem = message.role === 'system'
  const isStreaming = message.status === 'streaming'

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
        {!isUser && !isSystem && message.agentName && (
          <div className="text-xs font-medium text-gray-400 mb-1">
            {message.agentName}
          </div>
        )}

        {message.thinkingContent && (
          <ThinkingBlock
            content={message.thinkingContent}
            isStreaming={isStreaming}
          />
        )}

        {message.toolCalls?.map((tc) => (
          <ToolCallBlock key={tc.id} toolCall={tc} />
        ))}

        <div className="text-sm leading-relaxed">
          {isUser ? (
            message.content
          ) : (
            <MarkdownRenderer content={message.content} />
          )}
        </div>

        <div className="flex items-center justify-end gap-2 mt-1">
          {isStreaming && (
            <span className="inline-block w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
          )}
          {message.timestamp && (
            <time className="text-xs text-gray-500">{message.timestamp}</time>
          )}
        </div>
      </div>
    </div>
  )
}
