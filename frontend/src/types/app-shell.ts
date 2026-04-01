import type { Agent as ChatAgent } from './chat'

/**
 * Shared shell state exposed to routed pages.
 */
export interface AppShellOutletContext {
  activeAgent: ChatAgent | null
  chatReloadKey: number
  openSettings: () => void
  reloadChat: () => void
  setActiveAgent: (agent: ChatAgent | null) => void
}
