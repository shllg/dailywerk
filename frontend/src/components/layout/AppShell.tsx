import { useCallback, useMemo, useState } from 'react'
import { Outlet, useLocation } from 'react-router'
import { getRouteMeta } from '../../config/navigation'
import { SettingsDrawer } from '../settings/SettingsDrawer'
import { useAuth } from '../../hooks/useAuth'
import type { Agent as ChatAgent } from '../../types/chat'
import type { AppShellOutletContext } from '../../types/app-shell'
import { AppHeader } from './AppHeader'
import { AppSidebar } from './AppSidebar'

export function AppShell() {
  const { logout, token, user, workspace } = useAuth()
  const location = useLocation()
  const [isSidebarCollapsed, setIsSidebarCollapsed] = useState(false)
  const [isMobileSidebarOpen, setIsMobileSidebarOpen] = useState(false)
  const [isSettingsOpen, setIsSettingsOpen] = useState(false)
  const [chatAgent, setChatAgent] = useState<ChatAgent | null>(null)
  const [chatReloadKey, setChatReloadKey] = useState(0)
  const routeMeta = getRouteMeta(location.pathname)

  const openSettings = useCallback(() => {
    setIsSettingsOpen(true)
  }, [])

  const closeSettings = useCallback(() => {
    setIsSettingsOpen(false)
  }, [])

  const reloadChat = useCallback(() => {
    setChatReloadKey((count) => count + 1)
  }, [])

  const outletContext = useMemo<AppShellOutletContext>(
    () => ({
      activeAgent: chatAgent,
      chatReloadKey,
      openSettings,
      reloadChat,
      setActiveAgent: setChatAgent,
    }),
    [chatAgent, chatReloadKey, openSettings, reloadChat],
  )

  if (!token || !user || !workspace) {
    return null
  }

  return (
    <div className="min-h-screen bg-[radial-gradient(circle_at_top_left,_rgba(34,211,238,0.16),_transparent_28%),radial-gradient(circle_at_top_right,_rgba(245,158,11,0.12),_transparent_26%),linear-gradient(180deg,_#050816_0%,_#020617_48%,_#02030A_100%)] text-white">
      <div className="mx-auto flex min-h-screen max-w-[1600px] gap-4 p-4 sm:p-5">
        <AppSidebar
          activeAgent={chatAgent}
          isCollapsed={isSidebarCollapsed}
          isMobileOpen={isMobileSidebarOpen}
          onCloseMobile={() => setIsMobileSidebarOpen(false)}
          onOpenSettings={openSettings}
        />

        <div className="flex min-w-0 flex-1 flex-col gap-4 lg:pl-0">
          <AppHeader
            canConfigureAgent={Boolean(chatAgent)}
            description={routeMeta.description}
            isSidebarCollapsed={isSidebarCollapsed}
            onLogout={logout}
            onOpenMobileSidebar={() => setIsMobileSidebarOpen(true)}
            onOpenSettings={openSettings}
            onToggleSidebar={() =>
              setIsSidebarCollapsed((collapsed) => !collapsed)
            }
            title={routeMeta.title}
            userEmail={user.email}
            workspaceName={workspace.name}
          />

          <main className="flex min-h-0 flex-1">
            <Outlet context={outletContext} />
          </main>
        </div>
      </div>

      <SettingsDrawer
        agentId={chatAgent?.id ?? null}
        agentName={chatAgent?.name ?? null}
        isOpen={isSettingsOpen}
        onClose={closeSettings}
        onAgentUpdated={(agent) => {
          setChatAgent({
            id: agent.id,
            slug: agent.slug,
            name: agent.name,
          })
          reloadChat()
        }}
      />
    </div>
  )
}
