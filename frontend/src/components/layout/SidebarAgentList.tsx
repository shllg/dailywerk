import { Link } from 'react-router'
import type { Agent as ChatAgent } from '../../types/chat'

export interface SidebarAgentListProps {
  activeAgent: ChatAgent | null
  isCollapsed: boolean
  onNavigate: () => void
  onOpenSettings: () => void
}

export function SidebarAgentList({
  activeAgent,
  isCollapsed,
  onNavigate,
  onOpenSettings,
}: SidebarAgentListProps) {
  const agentName = activeAgent?.name || 'Main agent'
  const agentSlug = activeAgent?.slug || 'main'

  return (
    <div className="rounded-[26px] border border-white/10 bg-[linear-gradient(180deg,rgba(14,23,43,0.96),rgba(8,15,30,0.92))] p-3">
      {!isCollapsed && (
        <div className="mb-3 flex items-center justify-between gap-3 px-1">
          <div>
            <p className="text-[11px] font-semibold uppercase tracking-[0.24em] text-slate-500">
              Agents
            </p>
            <p className="mt-1 text-xs text-slate-400">Workspace roster</p>
          </div>
          <span className="rounded-full border border-emerald-300/20 bg-emerald-400/10 px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.2em] text-emerald-100">
            1 live
          </span>
        </div>
      )}

      <Link
        to="/chat"
        onClick={onNavigate}
        className={`flex items-center gap-3 rounded-[22px] border border-cyan-300/25 bg-cyan-400/10 px-3 py-3 text-slate-50 transition hover:border-cyan-200/40 hover:bg-cyan-400/15 ${
          isCollapsed ? 'justify-center' : ''
        }`}
        title={agentName}
      >
        <span className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl border border-white/10 bg-slate-950/80 text-sm font-semibold uppercase text-cyan-100">
          {agentName.slice(0, 1)}
        </span>

        {!isCollapsed && (
          <span className="min-w-0 flex-1">
            <span className="block truncate text-sm font-medium">{agentName}</span>
            <span className="mt-0.5 block text-xs text-cyan-100/70">
              Default agent · {agentSlug}
            </span>
          </span>
        )}
      </Link>

      {!isCollapsed && (
        <button
          type="button"
          onClick={onOpenSettings}
          disabled={!activeAgent}
          className="mt-3 inline-flex w-full items-center justify-center rounded-full border border-white/10 bg-white/[0.04] px-3 py-2 text-sm font-medium text-slate-200 transition hover:border-white/20 hover:bg-white/[0.08] disabled:cursor-not-allowed disabled:opacity-50"
        >
          Configure active agent
        </button>
      )}
    </div>
  )
}
