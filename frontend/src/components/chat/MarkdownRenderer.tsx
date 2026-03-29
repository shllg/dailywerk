import Markdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { CodeBlock } from './CodeBlock'

export interface MarkdownRendererProps {
  content: string
}

export function MarkdownRenderer({ content }: MarkdownRendererProps) {
  return (
    <Markdown
      remarkPlugins={[remarkGfm]}
      components={{
        code({ className, children, ...props }) {
          const match = /language-(\w+)/.exec(className || '')
          const codeString = String(children).replace(/\n$/, '')

          if (match) {
            return <CodeBlock code={codeString} language={match[1]} />
          }

          return (
            <code
              className="bg-gray-700 px-1.5 py-0.5 rounded text-sm font-mono"
              {...props}
            >
              {children}
            </code>
          )
        },
        p({ children }) {
          return <p className="mb-2 last:mb-0">{children}</p>
        },
        ul({ children }) {
          return <ul className="list-disc ml-4 mb-2">{children}</ul>
        },
        ol({ children }) {
          return <ol className="list-decimal ml-4 mb-2">{children}</ol>
        },
        li({ children }) {
          return <li className="mb-1">{children}</li>
        },
        a({ href, children }) {
          return (
            <a
              href={href}
              className="text-blue-400 hover:underline"
              target="_blank"
              rel="noopener noreferrer"
            >
              {children}
            </a>
          )
        },
        blockquote({ children }) {
          return (
            <blockquote className="border-l-2 border-gray-600 pl-3 italic text-gray-400 my-2">
              {children}
            </blockquote>
          )
        },
        table({ children }) {
          return (
            <div className="overflow-x-auto my-2">
              <table className="min-w-full text-sm border-collapse">
                {children}
              </table>
            </div>
          )
        },
        th({ children }) {
          return (
            <th className="border border-gray-700 px-3 py-1.5 bg-gray-800 text-left font-medium">
              {children}
            </th>
          )
        },
        td({ children }) {
          return (
            <td className="border border-gray-700 px-3 py-1.5">
              {children}
            </td>
          )
        },
        hr() {
          return <hr className="border-gray-700 my-3" />
        },
      }}
    >
      {content}
    </Markdown>
  )
}
