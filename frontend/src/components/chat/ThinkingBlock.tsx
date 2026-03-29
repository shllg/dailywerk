import { useState } from 'react'

export interface ThinkingBlockProps {
  content: string
  isStreaming?: boolean
}

export function ThinkingBlock({
  content,
  isStreaming = false,
}: ThinkingBlockProps) {
  const [isExpanded, setIsExpanded] = useState(false)

  return (
    <div className="my-2 rounded-lg border border-gray-700 bg-gray-900/50 overflow-hidden">
      <button
        onClick={() => setIsExpanded(!isExpanded)}
        className="w-full flex items-center gap-2 px-3 py-2 text-xs text-gray-400 hover:text-gray-300 transition-colors"
      >
        <svg
          className={`w-3 h-3 transition-transform ${isExpanded ? 'rotate-90' : ''}`}
          fill="currentColor"
          viewBox="0 0 20 20"
        >
          <path
            fillRule="evenodd"
            d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z"
            clipRule="evenodd"
          />
        </svg>
        <span className="font-medium">Thinking</span>
        {isStreaming && (
          <span className="inline-block w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse" />
        )}
      </button>
      {isExpanded && (
        <div className="px-3 pb-3 text-xs text-gray-500 font-mono leading-relaxed whitespace-pre-wrap border-t border-gray-700/50 pt-2">
          {content}
        </div>
      )}
    </div>
  )
}
