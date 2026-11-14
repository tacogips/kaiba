import { describe, expect, test } from 'bun:test'
import { NoteGraphQLClient, NoteTransportError, type NoteClientEnvironment } from './client'
import type { SearchEngineSettings } from './types'
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
    const page = await new NoteGraphQLClient(harness.value).engineSearchNotes({ query: 'q' })
    const body = requestBody(harness.requests[0])
    expect(body.operationName).toBe('EngineSearchNotes')
    expect(body.query).toContain('engineSearchNotes(')
    expect(body.variables).toEqual({ query: 'q' })
    expect(body.query).toContain('reasons { kind tags }')
    expect(body.query).toContain('facets { tagClasses')
    expect(page).toEqual({ hits: [], facets: null })
  })

  test('engine search passes ontology filters and facet opt-in', async () => {
    const facets = { tagClasses: [{ value: 'person', count: 2 }], tags: [] }
    const harness = environment([{ data: { engineSearchNotes: {
      result: { accepted: true, status: 'ok', diagnostics: [] }, value: [], facets,
    } } }])
    const page = await new NoteGraphQLClient(harness.value).engineSearchNotes({
      query: 'Ada', tagFilter: ['Ada'], tagClassFilter: ['person'], expandOntology: true, facets: true,
    })
    expect(requestBody(harness.requests[0]).variables).toEqual({
      query: 'Ada', tagFilter: ['Ada'], tagClassFilter: ['person'], expandOntology: true, facets: true,
    })
    expect(page.facets).toEqual(facets)
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
    expect(requestBody(harness.requests[0]).query).toContain('reasons { kind tags }')
  })

  test('settings query returns null when the server does not accept the field', async () => {
    const harness = environment([{ data: { searchEngineSettings: {
      result: { accepted: false, status: 'not-found', diagnostics: [] }, value: null,
    } } }])
    expect(await new NoteGraphQLClient(harness.value).searchEngineSettings()).toBeNull()
  })

  test('settings mutations send secrets only when supplied in mutation input', async () => {
    const value: SearchEngineSettings = {
      managedBy: 'store', kind: 'meilisearch', url: 'https://search.example', indexPrefix: 'kaiba',
      authMode: 'apiKey', username: null, hasSecret: true, verifyTLS: true, requestTimeoutSeconds: 10,
      adapters: [], active: true,
    }
    const harness = environment([
      { data: { updateSearchEngineSettings: { result: { accepted: true, status: 'ok', diagnostics: [] }, value } } },
      { data: { testSearchEngineConnection: { result: { accepted: true, status: 'ok', diagnostics: [] }, value: { available: true, status: 'available', detail: 'green' } } } },
    ])
    const client = new NoteGraphQLClient(harness.value)
    await client.updateSearchEngineSettings({ kind: 'meilisearch', authMode: 'apiKey', secret: 'provided-only-in-variable' })
    await client.testSearchEngineConnection({ kind: 'meilisearch', authMode: 'apiKey', secret: undefined })
    expect(requestBody(harness.requests[0]).operationName).toBe('UpdateSearchEngineSettings')
    expect(requestBody(harness.requests[0]).variables).toEqual({ input: { kind: 'meilisearch', authMode: 'apiKey', secret: 'provided-only-in-variable' } })
    expect(requestBody(harness.requests[1]).operationName).toBe('TestSearchEngineConnection')
    expect(requestBody(harness.requests[1]).variables).toEqual({ input: { kind: 'meilisearch', authMode: 'apiKey' } })
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
