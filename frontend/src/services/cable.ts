import { createConsumer } from '@rails/actioncable'

const consumer = createConsumer('/cable')

export default consumer
