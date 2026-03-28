import { render, screen } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import App from './App'

describe('App', () => {
  it('renders the app title', () => {
    render(<App />)
    expect(screen.getByText('DailyWerk')).toBeInTheDocument()
  })

  it('shows connecting message initially', () => {
    render(<App />)
    expect(screen.getByText('Connecting to API...')).toBeInTheDocument()
  })
})
