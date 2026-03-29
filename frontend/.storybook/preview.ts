import { __definePreview as definePreview } from '@storybook/react'
import '../src/index.css'

export default definePreview({
  parameters: {
    backgrounds: {
      default: 'dark',
      values: [
        { name: 'dark', value: '#030712' },
        { name: 'light', value: '#f9fafb' },
      ],
    },
  },
})
