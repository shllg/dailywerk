import { useOutletContext } from 'react-router'
import type { AppShellOutletContext } from '../types/app-shell'

/**
 * Access routed shell state without threading props through every page.
 */
export function useAppShell() {
  return useOutletContext<AppShellOutletContext>()
}
