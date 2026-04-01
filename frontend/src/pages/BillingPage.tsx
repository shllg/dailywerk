import { PlaceholderPage } from '../components/ui/PlaceholderPage'

export function BillingPage() {
  return (
    <PlaceholderPage
      eyebrow="Usage and credits"
      title="Billing, credits, and plan health"
      description="Credits, usage history, BYOK posture, and subscription state need their own surface instead of being hidden inside the agent drawer. This route prepares that split while the current implementation stays lean."
      footer="The billing RFC already defines balance and transaction endpoints plus a header badge, so this page is the natural destination once those APIs ship."
      highlights={[
        'Credit balance',
        'Usage visibility',
        'BYOK-aware billing',
      ]}
      panels={[
        {
          title: 'Credits',
          description:
            'Available and reserved credits should be visible at a glance and drill down into transaction history.',
        },
        {
          title: 'Usage breakdown',
          description:
            'LLM cost, search usage, and future bridge usage all feed into the same billing story.',
        },
        {
          title: 'Plan controls',
          description:
            'Subscription state, overage posture, and future add-ons like managed Signal belong in the same area.',
        },
      ]}
    />
  )
}
