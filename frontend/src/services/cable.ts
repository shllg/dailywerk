import { createConsumer } from '@rails/actioncable'

export function createAuthenticatedConsumer(ticket: string) {
  return createConsumer(`/cable?ticket=${encodeURIComponent(ticket)}`)
}
