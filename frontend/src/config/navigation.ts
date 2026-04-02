import type { AppNavItem, AppNavSection, AppRouteMeta } from '../types/navigation'

/**
 * Dashboard navigation ordered around the product surfaces already described in
 * the PRDs, while keeping chat as the default entry point.
 */
export const APP_NAVIGATION: AppNavSection[] = [
  {
    title: 'Workspace',
    items: [
      {
        label: 'Chat',
        path: '/chat',
        icon: 'chat',
        description: 'Primary in-app conversation with your default agent.',
        badge: 'Live',
      },
      {
        label: 'Agents',
        path: '/agents',
        icon: 'agents',
        description: 'Agent roster, defaults, and future specialist handoffs.',
        badge: 'Roadmap',
      },
      {
        label: 'Gateways',
        path: '/gateways',
        icon: 'gateways',
        description: 'Telegram, Signal, web, and future channel bindings.',
        badge: 'Planned',
      },
      {
        label: 'Inbox',
        path: '/inbox',
        icon: 'inbox',
        description: 'Inbound email routing, allowlists, and active mailbox tools.',
        badge: 'Planned',
      },
    ],
  },
  {
    title: 'Knowledge',
    items: [
      {
        label: 'Memory',
        path: '/memory',
        icon: 'agents',
        description: 'Structured long-term memory, shared/private scopes, and recall debugging.',
        badge: 'Live',
      },
      {
        label: 'Vault',
        path: '/vault',
        icon: 'vault',
        description: 'Obsidian sync, vault guides, and future file browsing.',
        badge: 'Planned',
      },
      {
        label: 'Billing',
        path: '/billing',
        icon: 'billing',
        description: 'Credits, usage, BYOK posture, and cost visibility.',
        badge: 'Planned',
      },
      {
        label: 'Integrations',
        path: '/integrations',
        icon: 'integrations',
        description: 'MCP servers, provider credentials, and connected services.',
        badge: 'Planned',
      },
    ],
  },
  {
    title: 'Account',
    items: [
      {
        label: 'Profile',
        path: '/profile',
        icon: 'profile',
        description: 'Identity, workspace context, and member-facing account info.',
        badge: 'Placeholder',
      },
      {
        label: 'Settings',
        path: '/settings',
        icon: 'settings',
        description: 'General app preferences and entry points into deeper config.',
        badge: 'Placeholder',
      },
    ],
  },
]

const ROUTE_META = APP_NAVIGATION.flatMap((section) => section.items).reduce<
  Record<string, AppRouteMeta>
>((accumulator, item) => {
  accumulator[item.path] = {
    title: item.label,
    description: item.description,
  }

  return accumulator
}, {})

export function getRouteMeta(pathname: string): AppRouteMeta {
  return (
    ROUTE_META[pathname] || {
      title: 'Chat',
      description: 'Primary in-app conversation with your default agent.',
    }
  )
}

export function getPrimaryAgentNavItem(): AppNavItem {
  return {
    label: 'Main agent',
    path: '/chat',
    icon: 'agents',
    description: 'Current default workspace agent.',
    badge: 'Live',
  }
}
