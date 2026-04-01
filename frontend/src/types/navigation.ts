export type AppNavIcon =
  | 'chat'
  | 'agents'
  | 'gateways'
  | 'inbox'
  | 'vault'
  | 'billing'
  | 'integrations'
  | 'profile'
  | 'settings'

export interface AppNavItem {
  badge?: string
  description: string
  icon: AppNavIcon
  label: string
  path: string
}

export interface AppNavSection {
  items: AppNavItem[]
  title: string
}

export interface AppRouteMeta {
  description: string
  title: string
}
