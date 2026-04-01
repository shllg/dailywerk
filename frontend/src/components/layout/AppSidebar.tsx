import { APP_NAVIGATION } from '../../config/navigation'
import type { Agent as ChatAgent } from '../../types/chat'
import { AppSidebarLink } from './AppSidebarLink'
import { AppSidebarSection } from './AppSidebarSection'
import { SidebarAgentList } from './SidebarAgentList'

export interface AppSidebarProps {
  activeAgent: ChatAgent | null
  isCollapsed: boolean
  isMobileOpen: boolean
  onCloseMobile: () => void
  onOpenSettings: () => void
}

export function AppSidebar({
  activeAgent,
  isCollapsed,
  isMobileOpen,
  onCloseMobile,
  onOpenSettings,
}: AppSidebarProps) {
  return (
    <>
      {isMobileOpen && (
        <button
          type="button"
          aria-label="Close navigation"
          onClick={onCloseMobile}
          className="fixed inset-0 z-40 bg-slate-950/70 backdrop-blur-sm lg:hidden"
        />
      )}

      <aside
        className={`fixed inset-y-4 left-4 z-50 flex w-[290px] flex-col rounded-[34px] border border-white/10 bg-[linear-gradient(180deg,rgba(7,16,31,0.98),rgba(2,6,23,0.96))] p-3 shadow-[0_25px_90px_rgba(2,6,23,0.55)] backdrop-blur-xl transition duration-300 lg:static lg:inset-auto lg:z-auto lg:shadow-[0_20px_70px_rgba(2,6,23,0.35)] ${
          isMobileOpen ? 'translate-x-0' : '-translate-x-[120%] lg:translate-x-0'
        } ${isCollapsed ? 'lg:w-24' : 'lg:w-[290px]'}`}
      >
        <div className={`mb-4 flex items-center gap-3 rounded-[26px] border border-white/10 bg-white/[0.04] px-3 py-3 ${isCollapsed ? 'justify-center' : ''}`}>
          <div className="inline-flex h-12 w-12 items-center justify-center rounded-2xl bg-[linear-gradient(135deg,rgba(34,211,238,0.28),rgba(245,158,11,0.25))] text-sm font-semibold uppercase tracking-[0.24em] text-white">
            DW
          </div>

          {!isCollapsed && (
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-semibold text-slate-100">DailyWerk</p>
              <p className="mt-0.5 text-xs text-slate-400">
                Chat-first workspace console
              </p>
            </div>
          )}

          <button
            type="button"
            onClick={onCloseMobile}
            className="inline-flex h-10 w-10 items-center justify-center rounded-2xl border border-white/10 bg-slate-950/60 text-slate-300 transition hover:border-white/20 hover:bg-slate-900 lg:hidden"
            aria-label="Close navigation"
          >
            <svg
              aria-hidden="true"
              viewBox="0 0 24 24"
              className="h-5 w-5"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.8"
              strokeLinecap="round"
            >
              <path d="m6 6 12 12M18 6 6 18" />
            </svg>
          </button>
        </div>

        <div className="flex-1 space-y-4 overflow-y-auto pr-1">
          <SidebarAgentList
            activeAgent={activeAgent}
            isCollapsed={isCollapsed}
            onNavigate={onCloseMobile}
            onOpenSettings={onOpenSettings}
          />

          {APP_NAVIGATION.map((section) => (
            <AppSidebarSection
              key={section.title}
              title={section.title}
              isCollapsed={isCollapsed}
            >
              {section.items.map((item) => (
                <AppSidebarLink
                  key={item.path}
                  item={item}
                  isCollapsed={isCollapsed}
                  onNavigate={onCloseMobile}
                />
              ))}
            </AppSidebarSection>
          ))}
        </div>
      </aside>
    </>
  )
}
