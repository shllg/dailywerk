import type { Session } from '../../types/chat'

export interface ConversationListProps {
  sessions: Session[]
  activeSessionId?: string
  onSelectSession: (sessionId: string) => void
  onNewSession: () => void
}

export function ConversationList({
  sessions,
  activeSessionId,
  onSelectSession,
  onNewSession,
}: ConversationListProps) {
  return (
    <div className="flex flex-col h-full bg-gray-900 border-r border-gray-800">
      <div className="flex items-center justify-between p-4 border-b border-gray-800">
        <h2 className="text-sm font-semibold text-gray-200">Conversations</h2>
        <button
          onClick={onNewSession}
          className="text-xs text-blue-400 hover:text-blue-300 transition-colors"
        >
          + New
        </button>
      </div>
      <div className="flex-1 overflow-y-auto">
        {sessions.map((session) => (
          <button
            key={session.id}
            onClick={() => onSelectSession(session.id)}
            className={`w-full text-left px-4 py-3 border-b border-gray-800/50 hover:bg-gray-800/50 transition-colors ${
              activeSessionId === session.id ? 'bg-gray-800' : ''
            }`}
          >
            <div className="flex items-center justify-between mb-1">
              <span className="text-sm font-medium text-gray-200 truncate">
                {session.title}
              </span>
              <span className="text-xs text-gray-500 ml-2 shrink-0">
                {session.lastMessageAt}
              </span>
            </div>
            {session.lastMessage && (
              <p className="text-xs text-gray-400 truncate">
                {session.lastMessage}
              </p>
            )}
            <div className="flex items-center gap-2 mt-1">
              <span className="text-xs text-gray-500">
                {session.agentName}
              </span>
              <span className="text-xs text-gray-600">
                {session.messageCount} msgs
              </span>
            </div>
          </button>
        ))}
      </div>
    </div>
  )
}
