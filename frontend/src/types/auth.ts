export interface AuthUser {
  id: string
  email: string
  name: string
}

export interface AuthWorkspace {
  id: string
  name: string
}

export interface SessionResponse {
  token: string
  user: AuthUser
  workspace: AuthWorkspace
}
