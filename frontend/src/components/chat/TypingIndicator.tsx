export interface TypingIndicatorProps {
  agentName?: string
}

export function TypingIndicator({ agentName }: TypingIndicatorProps) {
  return (
    <div className="flex justify-start">
      <div className="bg-gray-800 rounded-2xl px-4 py-3">
        {agentName && (
          <div className="text-xs font-medium text-gray-400 mb-1">
            {agentName}
          </div>
        )}
        <div className="flex gap-1.5 items-center h-5">
          <span className="w-2 h-2 rounded-full bg-gray-500 animate-bounce [animation-delay:0ms]" />
          <span className="w-2 h-2 rounded-full bg-gray-500 animate-bounce [animation-delay:150ms]" />
          <span className="w-2 h-2 rounded-full bg-gray-500 animate-bounce [animation-delay:300ms]" />
        </div>
      </div>
    </div>
  )
}
