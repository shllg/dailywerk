import { useCallback, useEffect, useRef, useState } from 'react'

export function useAutoScroll<T extends HTMLElement>() {
  const ref = useRef<T>(null)
  const [isAtBottom, setIsAtBottom] = useState(true)

  const checkIfAtBottom = useCallback(() => {
    const el = ref.current
    if (!el) return
    const threshold = 50
    setIsAtBottom(
      el.scrollHeight - el.scrollTop - el.clientHeight < threshold,
    )
  }, [])

  const scrollToBottom = useCallback(() => {
    const el = ref.current
    if (el) {
      el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
    }
  }, [])

  useEffect(() => {
    const el = ref.current
    if (!el) return
    el.addEventListener('scroll', checkIfAtBottom, { passive: true })
    return () => el.removeEventListener('scroll', checkIfAtBottom)
  }, [checkIfAtBottom])

  const scrollIfAtBottom = useCallback(() => {
    if (isAtBottom) scrollToBottom()
  }, [isAtBottom, scrollToBottom])

  return { ref, isAtBottom, scrollToBottom, scrollIfAtBottom }
}
