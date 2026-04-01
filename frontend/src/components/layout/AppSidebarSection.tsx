import type { ReactNode } from 'react'

export interface AppSidebarSectionProps {
  children: ReactNode
  isCollapsed: boolean
  title: string
}

export function AppSidebarSection({
  children,
  isCollapsed,
  title,
}: AppSidebarSectionProps) {
  return (
    <section className="space-y-2">
      {!isCollapsed && (
        <p className="px-3 text-[11px] font-semibold uppercase tracking-[0.28em] text-slate-500">
          {title}
        </p>
      )}
      <div className="space-y-1.5">{children}</div>
    </section>
  )
}
