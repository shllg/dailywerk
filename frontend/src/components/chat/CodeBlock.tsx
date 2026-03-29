import { useEffect, useState } from 'react'

export interface CodeBlockProps {
  code: string
  language?: string
}

export function CodeBlock({ code, language = 'text' }: CodeBlockProps) {
  const [html, setHtml] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    let cancelled = false
    // shiki's codeToHtml produces trusted HTML from source code strings.
    // The output contains only syntax-highlighted <span> elements — no user HTML passes through.
    import('shiki').then(({ codeToHtml }) =>
      codeToHtml(code, { lang: language, theme: 'github-dark' }).then(
        (result) => {
          if (!cancelled) setHtml(result)
        },
      ),
    )
    return () => {
      cancelled = true
    }
  }, [code, language])

  const handleCopy = () => {
    navigator.clipboard.writeText(code)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div className="rounded-lg overflow-hidden bg-gray-900 border border-gray-700 my-2">
      <div className="flex items-center justify-between px-3 py-1.5 bg-gray-800 border-b border-gray-700">
        <span className="text-xs text-gray-400 font-mono">{language}</span>
        <button
          onClick={handleCopy}
          className="text-xs text-gray-400 hover:text-gray-200 transition-colors"
        >
          {copied ? 'Copied!' : 'Copy'}
        </button>
      </div>
      {html ? (
        <div
          className="p-3 text-sm overflow-x-auto [&_pre]:!bg-transparent [&_pre]:!m-0 [&_pre]:!p-0"
          // Safe: shiki generates trusted HTML from code strings, no user HTML passes through
          dangerouslySetInnerHTML={{ __html: html }}
        />
      ) : (
        <pre className="p-3 text-sm text-gray-300 overflow-x-auto">
          <code>{code}</code>
        </pre>
      )}
    </div>
  )
}
