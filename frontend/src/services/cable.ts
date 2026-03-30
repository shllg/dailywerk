import { createConsumer } from '@rails/actioncable'

export function createAuthenticatedConsumer(token: string) {
  return createConsumer(`/cable?token=${encodeURIComponent(token)}`)
}
