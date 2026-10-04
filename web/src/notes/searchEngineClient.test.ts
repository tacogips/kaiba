import { describe, expect, test } from 'bun:test'
import { NoteGraphQLClient, NoteTransportError, type NoteClientEnvironment } from './client'
import { noteId as asNoteId } from './ids'

function environment(responses: unknown[]): {
  value: NoteClientEnvironment
  requests: Array<{ input: string; init?: RequestInit }>
} {
  const requests: Array<{ input: string; init?: RequestInit }> = []
  return {
    requests,
    value: {
      request: async (input, init) => {
        requests.push({ input: String(input), init })
        return new Response(JSON.stringify(responses.shift()), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      },
      getStoredItem: () => null,
      setStoredItem: () => undefined,
      removeStoredItem: () => undefined,
      currentURL: () => 'http://127.0.0.1:8787/',
      replaceURL: () => undefined,
    },
  }
}

function requestBody(request?: { init?: RequestInit }): {
  variables: Record<string, unknown>
  query: string
  operationName: string
} {
  return JSON.parse(String(request?.init?.body)) as {
    variables: Record<string, unknown>
    query: string
    operationName: string
  }
}

describe('search engine GraphQL client', () => {
  test('engine search omits absent optional variables', async () => {
    const harness = environment([{ data: { engineSearchNotes: {
      result: { accepted: true, status: 'ok', diagnostics: [] }, value: [],
    } } }])
    await new NoteGraphQLClient(harness.value).engineSearchNotes({ query: 'q' })
    const body = requestBody(harness.requests[0])
    expect(body.operationName).toBe('EngineSearchNotes')
    expect(body.query).toContain('engineSearchNotes(')
    expect(body.variables).toEqual({ query: 'q' })
  })

  test('engine search preserves the unavailable result status', async () => {
    const harness = environment([{ data: { engineSearchNotes: {
      result: { accepted: false, status: 'search-engine-unavailable', diagnostics: [] }, value: null,
    } } }])
    try {
      await new NoteGraphQLClient(harness.value).engineSearchNotes({ query: 'q' })
      throw new Error('expected an unavailable result error')
    } catch (error) {
      expect(error).toBeInstanceOf(NoteTransportError)
      expect((error as NoteTransportError).resultStatus).toBe('search-engine-unavailable')
    }
  })

  test('related notes sends the default limit', async () => {
    const harness = environment([{ data: { relatedNotes: {
      result: { accepted: true, status: 'ok', diagnostics: [] }, value: [],
    } } }])
    await new NoteGraphQLClient(harness.value).relatedNotes(asNoteId('source'))
    expect(requestBody(harness.requests[0]).variables).toEqual({ noteId: 'source', limit: 8 })
  })

  test('capability returns the accepted enabled value', async () => {
    const result = { accepted: true, status: 'ok', diagnostics: [] }
    const harness = environment([
      { data: { searchEngineCapability: { result, enabled: true } } },
      { data: { searchEngineCapability: { result, enabled: false } } },
    ])
    const client = new NoteGraphQLClient(harness.value)
    expect(await client.searchEngineCapability()).toBe(true)
    expect(await client.searchEngineCapability()).toBe(false)
  })
})
