import { useCallback, useEffect, useState } from 'react'
import type { Session } from '../../types/chat'
import { fetchSessions, createSession } from '../../services/chatApi'
import { ConversationList } from '../chat/ConversationList'
import { ChatContainer } from '../chat/ChatContainer'

export function ChatLayout() {
  const [sessions, setSessions] = useState<Session[]>([])
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)

  useEffect(() => {
    fetchSessions()
      .then((data) => {
        setSessions(data)
        if (data.length > 0) setActiveSessionId(data[0].id)
      })
      .catch(console.error)
  }, [])

  const handleNewSession = useCallback(() => {
    createSession()
      .then((session) => {
        setSessions((prev) => [session, ...prev])
        setActiveSessionId(session.id)
      })
      .catch(console.error)
  }, [])

  return (
    <div className="flex h-screen bg-gray-950 text-gray-100">
      <div className="w-72 shrink-0">
        <ConversationList
          sessions={sessions}
          activeSessionId={activeSessionId || undefined}
          onSelectSession={setActiveSessionId}
          onNewSession={handleNewSession}
        />
      </div>
      <div className="flex-1 flex flex-col">
        <ChatContainer sessionId={activeSessionId} />
      </div>
    </div>
  )
}
