import type { ToolCall } from '../../types/chat'

export interface ToolCallBlockProps {
  toolCall: ToolCall
}

const statusIcons: Record<ToolCall['status'], string> = {
  pending: '\u23F3',
  running: '\u2699\uFE0F',
  completed: '\u2705',
  error: '\u274C',
}

export function ToolCallBlock({ toolCall }: ToolCallBlockProps) {
  return (
    <div className="my-2 rounded-lg border border-gray-700 bg-gray-900/50 overflow-hidden">
      <div className="flex items-center gap-2 px-3 py-2">
        <span className="text-sm">{statusIcons[toolCall.status]}</span>
        <span className="text-xs font-medium text-gray-300">
          {toolCall.name}
        </span>
        {toolCall.status === 'running' && (
          <span className="inline-block w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
        )}
      </div>
      {toolCall.result && (
        <div className="px-3 pb-3 text-xs text-gray-400 font-mono border-t border-gray-700/50 pt-2 whitespace-pre-wrap">
          {toolCall.result}
        </div>
      )}
    </div>
  )
}
