import { NavLink } from 'react-router'
import type { AppNavItem, AppNavIcon } from '../../types/navigation'

export interface AppSidebarLinkProps {
  isCollapsed: boolean
  item: AppNavItem
  onNavigate: () => void
}

function renderIcon(icon: AppNavIcon) {
  switch (icon) {
    case 'chat':
      return <path d="M7 17.5 3.75 20V5.75A2.75 2.75 0 0 1 6.5 3h11A2.75 2.75 0 0 1 20.25 5.75v8.5A2.75 2.75 0 0 1 17.5 17H7Z" />
    case 'agents':
      return (
        <>
          <path d="M12 12.25a3.25 3.25 0 1 0 0-6.5 3.25 3.25 0 0 0 0 6.5Z" />
          <path d="M5.5 19.25a6.5 6.5 0 0 1 13 0" />
        </>
      )
    case 'gateways':
      return (
        <>
          <path d="M5 12h6m3 0h5" />
          <path d="M11 8.5 14.5 12 11 15.5" />
          <path d="M4.75 6.75h14.5v10.5H4.75Z" />
        </>
      )
    case 'inbox':
      return (
        <>
          <path d="M4.75 6.75h14.5v10.5H4.75Z" />
          <path d="m5 8 7 5 7-5" />
        </>
      )
    case 'vault':
      return (
        <>
          <path d="M5.75 4.75h8.5l4 4v10.5H5.75Z" />
          <path d="M14.25 4.75v4h4" />
        </>
      )
    case 'billing':
      return (
        <>
          <path d="M12 4.75v14.5" />
          <path d="M16.5 7.5c0-1.52-1.94-2.75-4.5-2.75S7.5 5.98 7.5 7.5s1.94 2.75 4.5 2.75 4.5 1.23 4.5 2.75S14.56 15.75 12 15.75s-4.5 1.23-4.5 2.75" />
        </>
      )
    case 'integrations':
      return (
        <>
          <path d="M8.25 8.25 4.75 12l3.5 3.75" />
          <path d="M15.75 8.25 19.25 12l-3.5 3.75" />
          <path d="M13.25 5.75 10.75 18.25" />
        </>
      )
    case 'profile':
      return (
        <>
          <path d="M12 11.5a3.75 3.75 0 1 0 0-7.5 3.75 3.75 0 0 0 0 7.5Z" />
          <path d="M5.25 19.5a6.75 6.75 0 0 1 13.5 0" />
        </>
      )
    case 'settings':
      return (
        <>
          <path d="m12 3.75 1.9 1.25 2.27-.32.82 2.14 2.12.84-.3 2.25L20.25 12l-1.44 1.84.3 2.25-2.12.84-.82 2.14-2.27-.32L12 20.25l-1.9-1.25-2.27.32-.82-2.14-2.12-.84.3-2.25L3.75 12l1.44-1.84-.3-2.25 2.12-.84.82-2.14L10.1 5 12 3.75Z" />
          <circle cx="12" cy="12" r="3.25" />
        </>
      )
  }
}

export function AppSidebarLink({
  isCollapsed,
  item,
  onNavigate,
}: AppSidebarLinkProps) {
  return (
    <NavLink
      to={item.path}
      title={item.label}
      onClick={onNavigate}
      className={({ isActive }) =>
        `group flex items-center gap-3 rounded-[22px] border px-3 py-3 transition ${
          isActive
            ? 'border-cyan-300/30 bg-cyan-400/15 text-slate-50'
            : 'border-transparent bg-white/[0.03] text-slate-300 hover:border-white/10 hover:bg-white/[0.06]'
        } ${isCollapsed ? 'justify-center' : ''}`
      }
    >
      <span className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl border border-white/10 bg-slate-950/70 text-slate-100">
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
          {renderIcon(item.icon)}
        </svg>
      </span>

      {!isCollapsed && (
        <span className="min-w-0 flex-1">
          <span className="block text-sm font-medium text-inherit">{item.label}</span>
          <span className="mt-0.5 block truncate text-xs text-slate-500 group-hover:text-slate-400">
            {item.description}
          </span>
        </span>
      )}

      {!isCollapsed && item.badge && (
        <span className="rounded-full border border-white/10 bg-white/[0.06] px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.2em] text-slate-300">
          {item.badge}
        </span>
      )}
    </NavLink>
  )
}
