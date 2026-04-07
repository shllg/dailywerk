// Module-level token ref for api.ts to access without React context
let currentToken: string | null = null

export function getToken(): string | null {
  return currentToken
}

export function setCurrentToken(t: string | null): void {
  currentToken = t
}
