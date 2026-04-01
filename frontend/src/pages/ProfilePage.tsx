import { PlaceholderPage } from '../components/ui/PlaceholderPage'

export function ProfilePage() {
  return (
    <PlaceholderPage
      eyebrow="Account context"
      title="Profile and workspace identity"
      description="The current app already knows the authenticated user and active workspace. This page reserves a clean place for personal account data, workspace membership details, and future approval or role signals."
      footer="Keeping profile separate from system settings prevents the settings drawer from becoming the dumping ground for every account-level detail."
      highlights={[
        'Authenticated identity',
        'Workspace ownership',
        'Future membership roles',
      ]}
      panels={[
        {
          title: 'Identity',
          description:
            'Name, email, and login method belong here once WorkOS and richer profile fields are exposed in the frontend.',
        },
        {
          title: 'Workspace view',
          description:
            'This area can show workspace membership and role context without overloading the chat shell header.',
        },
        {
          title: 'Approval posture',
          description:
            'Future plan or account status indicators have a natural home here if onboarding and admin controls expand.',
        },
      ]}
    />
  )
}
