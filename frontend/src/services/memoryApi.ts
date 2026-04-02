import type {
  MemoryEntry,
  MemoryIndexResponse,
  MemoryMutationInput,
} from '../types/memory'
import { apiRequest } from './api'

export function fetchMemoryEntries(): Promise<MemoryIndexResponse> {
  return apiRequest<MemoryIndexResponse>('/memory')
}

export async function createMemoryEntry(
  input: MemoryMutationInput,
): Promise<MemoryEntry> {
  const response = await apiRequest<{ entry: MemoryEntry }>('/memory', {
    method: 'POST',
    body: JSON.stringify({ memory_entry: input }),
  })

  return response.entry
}

export async function updateMemoryEntry(
  id: string,
  input: MemoryMutationInput,
): Promise<MemoryEntry> {
  const response = await apiRequest<{ entry: MemoryEntry }>(`/memory/${id}`, {
    method: 'PATCH',
    body: JSON.stringify({ memory_entry: input }),
  })

  return response.entry
}

export async function deactivateMemoryEntry(
  id: string,
  reason?: string,
): Promise<MemoryEntry> {
  const response = await apiRequest<{ entry: MemoryEntry }>(`/memory/${id}`, {
    method: 'DELETE',
    body: JSON.stringify({ reason }),
  })

  return response.entry
}
