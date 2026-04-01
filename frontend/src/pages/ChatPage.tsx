import { ChatContainer } from '../components/chat/ChatContainer'
import { useAppShell } from '../hooks/useAppShell'
import { useAuth } from '../hooks/useAuth'

export function ChatPage() {
  const { chatReloadKey, setActiveAgent } = useAppShell()
  const { token } = useAuth()

  if (!token) {
    return null
  }

  return (
    <div className="flex min-h-0 flex-1">
      <ChatContainer
        token={token}
        reloadKey={chatReloadKey}
        onAgentLoaded={setActiveAgent}
      />
    </div>
  )
}
