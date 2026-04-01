export interface AppHeaderProps {
  canConfigureAgent: boolean
  description: string
  isSidebarCollapsed: boolean
  onLogout: () => void
  onOpenMobileSidebar: () => void
  onOpenSettings: () => void
  onToggleSidebar: () => void
  title: string
  userEmail: string
  workspaceName: string
}

export function AppHeader({
  canConfigureAgent,
  description,
  isSidebarCollapsed,
  onLogout,
  onOpenMobileSidebar,
  onOpenSettings,
  onToggleSidebar,
  title,
  userEmail,
  workspaceName,
}: AppHeaderProps) {
  return (
    <header className="rounded-[30px] border border-white/10 bg-white/[0.04] px-4 py-4 shadow-[0_20px_70px_rgba(2,6,23,0.35)] backdrop-blur-xl sm:px-5">
      <div className="flex flex-col gap-4 xl:flex-row xl:items-center xl:justify-between">
        <div className="flex items-start gap-3">
          <button
            type="button"
            onClick={onOpenMobileSidebar}
            className="inline-flex h-11 w-11 items-center justify-center rounded-2xl border border-white/10 bg-slate-950/60 text-slate-200 transition hover:border-white/20 hover:bg-slate-900 lg:hidden"
            aria-label="Open navigation"
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
              <path d="M4 7h16M4 12h16M4 17h16" />
            </svg>
          </button>

          <button
            type="button"
            onClick={onToggleSidebar}
            className="hidden h-11 w-11 items-center justify-center rounded-2xl border border-white/10 bg-slate-950/60 text-slate-200 transition hover:border-white/20 hover:bg-slate-900 lg:inline-flex"
            aria-label={isSidebarCollapsed ? 'Expand navigation' : 'Collapse navigation'}
          >
            <svg
              aria-hidden="true"
              viewBox="0 0 24 24"
              className="h-5 w-5"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.8"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              {isSidebarCollapsed ? (
                <path d="m9 6 6 6-6 6" />
              ) : (
                <path d="m15 6-6 6 6 6" />
              )}
            </svg>
          </button>

          <div>
            <div className="flex flex-wrap items-center gap-2">
              <span className="rounded-full border border-amber-300/30 bg-amber-400/15 px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.24em] text-amber-100">
                DailyWerk
              </span>
              <span className="rounded-full border border-cyan-400/20 bg-cyan-400/10 px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.24em] text-cyan-100">
                {workspaceName}
              </span>
            </div>
            <h1 className="mt-3 text-2xl font-semibold tracking-tight text-slate-50 sm:text-3xl">
              {title}
            </h1>
            <p className="mt-1 max-w-2xl text-sm text-slate-400">{description}</p>
          </div>
        </div>

        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <div className="rounded-[24px] border border-white/10 bg-slate-950/55 px-4 py-3">
            <p className="text-[11px] font-semibold uppercase tracking-[0.24em] text-slate-500">
              Workspace owner
            </p>
            <p className="mt-1 text-sm font-medium text-slate-100">{userEmail}</p>
          </div>

          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={onOpenSettings}
              disabled={!canConfigureAgent}
              className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-slate-950/70 px-4 py-2.5 text-sm font-medium text-slate-200 transition hover:border-white/20 hover:bg-slate-900 disabled:cursor-not-allowed disabled:opacity-50"
            >
              <svg
                aria-hidden="true"
                viewBox="0 0 24 24"
                className="h-4 w-4"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <path d="M12 3.75 13.9 5l2.27-.32.82 2.14 2.12.84-.3 2.25L20.25 12l-1.44 1.84.3 2.25-2.12.84-.82 2.14-2.27-.32L12 20.25l-1.9-1.25-2.27.32-.82-2.14-2.12-.84.3-2.25L3.75 12l1.44-1.84-.3-2.25 2.12-.84.82-2.14L10.1 5 12 3.75Z" />
                <circle cx="12" cy="12" r="3.25" />
              </svg>
              Agent settings
            </button>

            <button
              type="button"
              onClick={onLogout}
              className="rounded-full border border-white/10 bg-slate-950/70 px-4 py-2.5 text-sm font-medium text-slate-200 transition hover:border-white/20 hover:bg-slate-900"
            >
              Logout
            </button>
          </div>
        </div>
      </div>
    </header>
  )
}
