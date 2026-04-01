export interface PlaceholderPanel {
  description: string
  title: string
}

export interface PlaceholderPageProps {
  description: string
  eyebrow: string
  footer: string
  highlights: string[]
  panels: PlaceholderPanel[]
  title: string
}

export function PlaceholderPage({
  description,
  eyebrow,
  footer,
  highlights,
  panels,
  title,
}: PlaceholderPageProps) {
  return (
    <div className="flex min-h-0 flex-1 flex-col gap-4">
      <section className="rounded-[32px] border border-white/10 bg-[linear-gradient(135deg,rgba(8,15,30,0.92),rgba(15,23,42,0.86))] p-6 shadow-[0_24px_90px_rgba(2,6,23,0.35)] sm:p-7">
        <div className="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
          <div className="max-w-3xl">
            <p className="text-[11px] font-semibold uppercase tracking-[0.3em] text-amber-100/80">
              {eyebrow}
            </p>
            <h2 className="mt-3 text-3xl font-semibold tracking-tight text-slate-50">
              {title}
            </h2>
            <p className="mt-3 text-sm leading-6 text-slate-400">{description}</p>
          </div>

          <div className="rounded-[28px] border border-cyan-300/20 bg-cyan-400/10 px-5 py-4 lg:max-w-sm">
            <p className="text-[11px] font-semibold uppercase tracking-[0.24em] text-cyan-100/80">
              Why this exists now
            </p>
            <p className="mt-2 text-sm leading-6 text-cyan-50/90">{footer}</p>
          </div>
        </div>

        <div className="mt-6 flex flex-wrap gap-2.5">
          {highlights.map((highlight) => (
            <span
              key={highlight}
              className="rounded-full border border-white/10 bg-white/[0.05] px-3.5 py-2 text-sm text-slate-200"
            >
              {highlight}
            </span>
          ))}
        </div>
      </section>

      <section className="grid gap-4 lg:grid-cols-3">
        {panels.map((panel) => (
          <article
            key={panel.title}
            className="rounded-[28px] border border-white/10 bg-white/[0.04] p-5 shadow-[0_16px_60px_rgba(2,6,23,0.24)] backdrop-blur-xl"
          >
            <p className="text-lg font-medium text-slate-50">{panel.title}</p>
            <p className="mt-2 text-sm leading-6 text-slate-400">
              {panel.description}
            </p>
          </article>
        ))}
      </section>
    </div>
  )
}
