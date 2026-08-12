import { describe, expect, test } from 'bun:test'
import {
  NoteGraphQLClient,
  NoteTransportError,
  notebookPageLimit,
  type NoteClientEnvironment,
} from './client'
import type { KanbanStatusSet } from './types'

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
      getSessionItem: (key) => storage.get(key) ?? null,
      setSessionItem: (key, value) => storage.set(key, value),
      removeSessionItem: (key) => { storage.delete(key) },
      appHeaders: () => ({}),
      currentURL: () => href,
      replaceURL: (value) => replacements.push(value),
    },
  }
}

describe('Note GraphQL transport', () => {
  test('sends RielaApp CSRF credentials, bounded scope variables, and notebook metadata selections', async () => {
    const harness = environment([{ data: { notebooks: { result: { accepted: true, status: 'ok', diagnostics: [] }, value: [] } } }])
    const client = new NoteGraphQLClient('riela-app', {
      ...harness.value,
      appHeaders: () => ({ 'X-Riela-CSRF': 'csrf' }),
      request: async (input, init) => {
        const headers = new Headers(init?.headers)
        expect(headers.get('X-Riela-CSRF')).toBe('csrf')
        return harness.value.request(input, init)
      },
    })
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
    expect(body.query).toContain('progress readOnly')
    expect(body.query).toContain('classId parentTagId')
    expect(harness.requests[0]?.init?.credentials).toBe('same-origin')
  })

  test('adopts the canonical notebook lock mutation response', async () => {
    const canonical = {
      notebookId: 'notebook-system-memory',
      title: 'System Memory',
      progress: 'none',
      readOnly: false,
      createdAt: '',
      updatedAt: '',
      tags: [],
    }
    const harness = environment([{ data: { setNotebookReadOnly: {
      result: { accepted: true, status: 'ok', diagnostics: [] },
      notebook: canonical,
    } } }])
    const client = new NoteGraphQLClient('riela-app', harness.value)

    expect(await client.setNotebookReadOnly(canonical.notebookId, false)).toEqual(canonical)
    const body = requestBody(harness.requests[0])
    expect(body.variables).toEqual({ notebookId: canonical.notebookId, readOnly: false })
    expect(body.query).toContain('setNotebookReadOnly')
  })

  test('preserves custom status names verbatim on reads and writes', async () => {
    const raw = {
      notebookId: 'book',
      title: 'Book',
      progress: 'future',
      createdAt: '',
      updatedAt: '',
      tags: [],
    }
    const canonical = { ...raw, progress: 'done' }
    const harness = environment([
      { data: { notebooks: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        value: [raw],
      } } },
      { data: { setNotebookProgress: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        notebook: raw,
      } } },
      { data: { notebook: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        value: canonical,
      } } },
    ])
    const client = new NoteGraphQLClient('riela-app', harness.value)
    // Custom status names must survive verbatim: coercing them (the old
    // unknown→'none' behavior) would poison expectedProgress CAS writes.
    expect(await client.notebooks(0, 'updatedAtDesc', [])).toMatchObject([
      { progress: 'future' },
    ])
    expect(await client.setProgress('book', 'done')).toMatchObject({
      progress: 'future',
    })
    expect(await client.notebook('book')).toMatchObject({
      progress: 'done',
    })
  })

  test('projects notebook read-only state and persists explicit unlocks', async () => {
    const notebook = {
      notebookId: 'system-memory',
      title: 'Riela System Memory',
      progress: 'none',
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
    const client = new NoteGraphQLClient('riela-app', harness.value)

    expect(await client.notebooks(0, 'updatedAtDesc', [])).toMatchObject([{ readOnly: true }])
    expect(await client.setNotebookReadOnly('system-memory', false)).toMatchObject({ readOnly: false })
    const body = requestBody(harness.requests[1])
    expect(body.operationName).toBe('SetNotebookReadOnly')
    expect(body.variables).toEqual({ notebookId: 'system-memory', readOnly: false })
  })

  test('uses the shared notebook page limit for note previews', async () => {
    const harness = environment([
      { data: { notes: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        value: [],
      } } },
    ])
    const client = new NoteGraphQLClient('riela-app', harness.value)

    await client.notes('book', notebookPageLimit)

    expect(requestBody(harness.requests[0]).variables).toEqual({
      notebookId: 'book',
      limit: notebookPageLimit,
      offset: notebookPageLimit,
    })
  })

  test('redeems CLI code, removes it from the URL, and keeps bearer in session scope', async () => {
    const harness = environment([
      { credential: { bearerToken: 'rn_session' } },
      { data: { tags: { result: { accepted: true, status: 'ok', diagnostics: [] }, value: [] } } },
    ], 'http://127.0.0.1:8787/note/register?code=once')
    const client = new NoteGraphQLClient('cli-serve', harness.value)
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
      notebook: { notebookId: 'book', title: 'Book', progress: 'none', createdAt: '', updatedAt: '', tags: [] },
    } } }])
    const client = new NoteGraphQLClient('riela-app', harness.value)
    await client.applyTagById('book', 'tag-urgent')
    const body = JSON.parse(String(harness.requests[0]?.init?.body)) as { variables: { input: Record<string, unknown> } }
    expect(body.variables.input).toEqual({
      notebookId: 'book',
      tagIds: ['tag-urgent'],
      provenance: 'human',
      assignedBy: 'kaiba-web',
    })
    expect(requestBody(harness.requests[0]).operationName).toBe('ApplyNotebookTagIds')
    expect(requestBody(harness.requests[0]).query).toContain('firstNotePreview noteCount')
  })

  test('sends create-only folder variables and human remove provenance', async () => {
    const created = {
      tagId: 'folder-child',
      name: 'Child',
      classId: 'folder',
      parentTagId: 'folder-root',
      isSystem: false,
      createdAt: '',
    }
    const notebook = {
      notebookId: 'book',
      title: 'Book',
      progress: 'none',
      createdAt: '',
      updatedAt: '',
      tags: [],
    }
    const harness = environment([
      { data: { defineNoteTag: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        tag: created,
      } } },
      { data: { removeNotebookTagById: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        notebook,
      } } },
    ])
    const client = new NoteGraphQLClient('riela-app', harness.value)

    expect(await client.defineFolder('Child', 'folder', 'folder-root')).toEqual(created)
    await client.removeTagById('book', 'folder-child')
    const defineBody = requestBody(harness.requests[0])
    const removeBody = requestBody(harness.requests[1])
    expect(defineBody.variables).toEqual({
      input: {
        name: 'Child',
        classId: 'folder',
        parentTagId: 'folder-root',
        createOnly: true,
      },
    })
    expect(removeBody.variables).toEqual({
      notebookId: 'book',
      tagId: 'folder-child',
      provenance: 'human',
    })
    expect(removeBody.operationName).toBe('RemoveNotebookTagById')
    expect(removeBody.query).toContain('firstNotePreview noteCount')
  })

  test('uses tag IDs for effective and assigned Kanban status sets', async () => {
    const statusSet: KanbanStatusSet = {
      setId: 'kanban-branch',
      name: 'Branch board',
      isSystem: false,
      statuses: [{ statusId: 'queued', name: 'queued', category: 'pending', position: 0 }],
    }
    const folder = {
      tagId: 'folder-archive-launch',
      name: 'Launch',
      classId: 'folder',
      parentTagId: 'folder-archive',
      statusSetId: statusSet.setId,
      isSystem: false,
      createdAt: '',
    }
    const harness = environment([
      { data: { effectiveKanbanStatusesByTagId: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        value: statusSet,
      } } },
      { data: { assignKanbanStatusSetByTagId: {
        result: { accepted: true, status: 'ok', diagnostics: [] },
        tag: folder,
      } } },
    ])
    const client = new NoteGraphQLClient('riela-app', harness.value)

    expect(await client.effectiveKanbanStatusesByTagId(folder.tagId)).toEqual(statusSet)
    expect(await client.assignKanbanStatusSetByTagId(folder.tagId, statusSet.setId)).toEqual(folder)

    const effectiveBody = requestBody(harness.requests[0])
    expect(effectiveBody.operationName).toBe('EffectiveKanbanStatusesByTagId')
    expect(effectiveBody.variables).toEqual({ tagId: folder.tagId })
    expect(effectiveBody.query).toContain('effectiveKanbanStatusesByTagId(tagId: $tagId)')
    const assignedBody = requestBody(harness.requests[1])
    expect(assignedBody.operationName).toBe('AssignKanbanStatusSetByTagId')
    expect(assignedBody.variables).toEqual({ tagId: folder.tagId, setId: statusSet.setId })
    expect(assignedBody.query).toContain('assignKanbanStatusSetByTagId(tagId: $tagId, setId: $setId)')
  })

  test('queues notebook translation and surfaces the pending notebook id', async () => {
    const harness = environment([{ data: { requestNotebookTranslation: {
      result: { accepted: true, status: 'ok', diagnostics: [] },
      translationNotebookId: 'notebook-translated',
      status: 'queued',
    } } }])
    const client = new NoteGraphQLClient('riela-app', harness.value)

    expect(await client.requestNotebookTranslation({
      notebookId: 'notebook-source',
      targetLanguage: 'English',
    })).toEqual({ translationNotebookId: 'notebook-translated', status: 'queued' })
    const body = requestBody(harness.requests[0])
    expect(body.variables).toEqual({
      input: { notebookId: 'notebook-source', targetLanguage: 'English' },
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
    await expectErrorKind(new NoteGraphQLClient('riela-app', rejected.value).tags(), 'result')

    const graphQL = environment([{ errors: [{ message: 'schema mismatch' }] }])
    await expectErrorKind(new NoteGraphQLClient('riela-app', graphQL.value).tags(), 'graphql')
  })

  test('distinguishes HTTP failures and clears only the CLI session bearer on 401', async () => {
    const harness = environment([])
    harness.storage.set('kaiba-note-bearer', 'rn_expired')
    const client = new NoteGraphQLClient('cli-serve', {
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
