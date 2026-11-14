import { notebookId as asNotebookId, tagId as asTagId } from './ids'
import { describe, expect, test } from 'bun:test'
import {
  NoteGraphQLClient,
  NoteTransportError,
  notebookPageLimit,
  type NoteClientEnvironment,
} from './client'

function environment(
  responses: unknown[],
  href = 'http://127.0.0.1:8787/',
): { value: NoteClientEnvironment; requests: Array<{ input: string; init?: RequestInit }>; storage: Map<string, string>; replacements: string[] } {
  const requests: Array<{ input: string; init?: RequestInit }> = []
  const storage = new Map<string, string>()
  const replacements: string[] = []
  return {
    requests,
    storage,
    replacements,
    value: {
      request: async (input, init) => {
        requests.push({ input: String(input), init })
        return new Response(JSON.stringify(responses.shift()), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      },
      getStoredItem: (key) => storage.get(key) ?? null,
      setStoredItem: (key, value) => storage.set(key, value),
      removeStoredItem: (key) => { storage.delete(key) },
      currentURL: () => href,
      replaceURL: (value) => replacements.push(value),
    },
  }
}

describe('Note GraphQL transport', () => {
  test('sends bounded scope variables and notebook metadata selections', async () => {
    const harness = environment([{ data: { notebooks: { result: { accepted: true, status: 'ok', diagnostics: [] }, value: [] } } }])
    const client = new NoteGraphQLClient(harness.value)
    await client.notebooks(200, 'updatedAtDesc', [['folder-work'], ['topic-launch']])
    const body = requestBody(harness.requests[0])
    expect(body.variables).toEqual({
      limit: 200,
      offset: 200,
      sort: 'updatedAtDesc',
      tagFilterIdGroups: [['folder-work'], ['topic-launch']],
    })
    expect(body.query).toContain('$tagFilterIdGroups: [[String!]!]')
    expect(body.query).toContain('firstNotePreview noteCount')
    expect(body.query).toContain('title readOnly')
    expect(body.query).toContain('classId parentTagId')
    expect(harness.requests[0]?.init?.credentials).toBe('same-origin')
  })

  test('adopts the canonical notebook lock mutation response', async () => {
    const canonical = {
      notebookId: asNotebookId('notebook-system-memory'),
      title: 'System Memory',
      readOnly: false,
      createdAt: '',
      updatedAt: '',
      tags: [],
    }
    const harness = environment([{ data: { setNotebookReadOnly: {
      result: { accepted: true, status: 'ok', diagnostics: [] },
      notebook: canonical,
    } } }])
    const client = new NoteGraphQLClient(harness.value)

    expect(await client.setNotebookReadOnly(canonical.notebookId, false)).toEqual(canonical)
    const body = requestBody(harness.requests[0])
    expect(body.variables).toEqual({ notebookId: canonical.notebookId, readOnly: false })
    expect(body.query).toContain('setNotebookReadOnly')
  })

  test('projects notebook read-only state and persists explicit unlocks', async () => {
    const notebook = {
      notebookId: asNotebookId('system-memory'),
      title: 'Riela System Memory',
      readOnly: true,
      createdAt: '',
      updatedAt: '',
      tags: [],
    }
    const harness = environment([
      { data: { notebooks: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        value: [notebook],
      } } },
      { data: { setNotebookReadOnly: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        notebook: { ...notebook, readOnly: false },
      } } },
    ])
    const client = new NoteGraphQLClient(harness.value)

    expect(await client.notebooks(0, 'updatedAtDesc', [])).toMatchObject([{ readOnly: true }])
    expect(await client.setNotebookReadOnly(asNotebookId('system-memory'), false)).toMatchObject({ readOnly: false })
    const body = requestBody(harness.requests[1])
    expect(body.operationName).toBe('SetNotebookReadOnly')
    expect(body.variables).toEqual({ notebookId: asNotebookId('system-memory'), readOnly: false })
  })

  test('uses the shared notebook page limit for note previews', async () => {
    const harness = environment([
      { data: { notes: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        value: [],
      } } },
    ])
    const client = new NoteGraphQLClient(harness.value)

    await client.notes(asNotebookId('book'), notebookPageLimit)

    expect(requestBody(harness.requests[0]).variables).toEqual({
      notebookId: asNotebookId('book'),
      limit: notebookPageLimit,
      offset: notebookPageLimit,
    })
  })

  test('redeems CLI code, removes it from the URL, and keeps bearer in session scope', async () => {
    const harness = environment([
      { credential: { bearerToken: 'rn_session' } },
      { data: { tags: { result: { accepted: true, status: 'ok', diagnostics: [] }, value: [] } } },
    ], 'http://127.0.0.1:8787/note/register?code=once')
    const client = new NoteGraphQLClient(harness.value)
    await client.initialize()
    await client.tags()
    expect(harness.replacements).toEqual(['/note/register'])
    expect(harness.storage.get('kaiba-note-bearer')).toBe('rn_session')
    expect(new Headers(harness.requests[1]?.init?.headers).get('Authorization')).toBe('Bearer rn_session')
    expect(JSON.parse(String(harness.requests[0]?.init?.body))).toEqual({ code: 'once', displayName: 'Kaiba Web' })
  })

  test('sends explicit human provenance for catalog-selected tag membership', async () => {
    const harness = environment([{ data: { applyNotebookTagIds: {
      result: { accepted: true, status: 'ok', diagnostics: [] },
      notebook: { notebookId: asNotebookId('book'), title: 'Book', createdAt: '', updatedAt: '', tags: [] },
    } } }])
    const client = new NoteGraphQLClient(harness.value)
    await client.applyTagById(asNotebookId('book'), asTagId('tag-urgent'))
    const body = JSON.parse(String(harness.requests[0]?.init?.body)) as { variables: { input: Record<string, unknown> } }
    expect(body.variables.input).toEqual({
      notebookId: asNotebookId('book'),
      tagIds: [asTagId('tag-urgent')],
      provenance: 'human',
      assignedBy: 'kaiba-web',
    })
    expect(requestBody(harness.requests[0]).operationName).toBe('ApplyNotebookTagIds')
    expect(requestBody(harness.requests[0]).query).toContain('firstNotePreview noteCount')
  })

  test('sends human remove provenance for notebook tag removal', async () => {
    const notebook = {
      notebookId: asNotebookId('book'),
      title: 'Book',
      createdAt: '',
      updatedAt: '',
      tags: [],
    }
    const harness = environment([
      { data: { removeNotebookTagById: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        notebook,
      } } },
    ])
    const client = new NoteGraphQLClient(harness.value)

    await client.removeTagById(asNotebookId('book'), asTagId('folder-child'))
    const removeBody = requestBody(harness.requests[0])
    expect(removeBody.variables).toEqual({
      notebookId: asNotebookId('book'),
      tagId: asTagId('folder-child'),
      provenance: 'human',
    })
    expect(removeBody.operationName).toBe('RemoveNotebookTagById')
    expect(removeBody.query).toContain('firstNotePreview noteCount')
  })

  test('queues notebook translation and surfaces the pending notebook id', async () => {
    const harness = environment([{ data: { requestNotebookTranslation: {
      result: { accepted: true, status: 'ok', diagnostics: [] },
      translationNotebookId: asNotebookId('notebook-translated'),
      status: 'queued',
    } } }])
    const client = new NoteGraphQLClient(harness.value)

    expect(await client.requestNotebookTranslation({
      notebookId: asNotebookId('notebook-source'),
      targetLanguage: 'English',
    })).toEqual({ translationNotebookId: asNotebookId('notebook-translated'), status: 'queued' })
    const body = requestBody(harness.requests[0])
    expect(body.variables).toEqual({
      input: { notebookId: asNotebookId('notebook-source'), targetLanguage: 'English' },
    })
    expect(body.query).toContain('requestNotebookTranslation')
  })

  test('distinguishes rejected results and GraphQL envelope failures', async () => {
    const rejected = environment([
      { data: { tags: {
        result: { accepted: false, status: 'invalid_request', diagnostics: ['tag collision'] },
        value: [],
      } } },
    ])
    await expectErrorKind(new NoteGraphQLClient(rejected.value).tags(), 'result')

    const graphQL = environment([{ errors: [{ message: 'schema mismatch' }] }])
    await expectErrorKind(new NoteGraphQLClient(graphQL.value).tags(), 'graphql')
  })

  test('distinguishes HTTP failures and clears only the CLI session bearer on 401', async () => {
    const harness = environment([])
    harness.storage.set('kaiba-note-bearer', 'rn_expired')
    const client = new NoteGraphQLClient({
      ...harness.value,
      request: async () => new Response(JSON.stringify({ error: 'expired' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    })

    await expectErrorKind(client.tags(), 'http', 401)
    expect(harness.storage.has('kaiba-note-bearer')).toBe(false)
  })
})

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

async function expectErrorKind(
  promise: Promise<unknown>,
  kind: NoteTransportError['kind'],
  status?: number,
): Promise<void> {
  try {
    await promise
    throw new Error(`expected ${kind} error`)
  } catch (error) {
    expect(error).toBeInstanceOf(NoteTransportError)
    expect((error as NoteTransportError).kind).toBe(kind)
    if (status !== undefined) expect((error as NoteTransportError).status).toBe(status)
  }
}
