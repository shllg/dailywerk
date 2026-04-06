import { useState } from 'react'

interface SessionContextCardProps {
  summary: string
}

export function SessionContextCard({ summary }: SessionContextCardProps) {
  const [expanded, setExpanded] = useState(false)

  const previewLength = 140
  const needsTruncation = summary.length > previewLength
  const preview = needsTruncation
    ? `${summary.slice(0, previewLength).trimEnd()}…`
    : summary

  return (
    <div className="mb-3 rounded-xl border border-white/5 bg-white/[0.02] px-4 py-3">
      <button
        type="button"
        onClick={() => setExpanded(!expanded)}
        className="flex w-full items-center gap-2 text-left text-xs text-slate-500 transition-colors hover:text-slate-400"
      >
        <span className="shrink-0 text-[10px] uppercase tracking-widest">
          Context from previous session
        </span>
        {needsTruncation && (
          <span className="ml-auto shrink-0 text-[10px] text-slate-600">
            {expanded ? 'collapse' : 'expand'}
          </span>
        )}
      </button>
      <p className="mt-1.5 text-xs leading-relaxed text-slate-500 whitespace-pre-line">
        {expanded || !needsTruncation ? summary : preview}
      </p>
    </div>
  )
}
