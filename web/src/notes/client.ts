import { api } from '../api'
import type {
  AgentChatMessageResult,
  AgentConversation,
  ControlResult,
  GraphQLEnvelope,
  HostMode,
  KanbanStatusSet,
  MutationPayload,
  Note,
  Notebook,
  NoteComment,
  NoteGraphNeighbor,
  NoteListSort,
  NoteSearchResult,
  NoteTag,
  NoteTagClass,
  QueryPayload,
} from './types'

const bearerKey = 'kaiba-note-bearer'
export const notebookPageLimit = 200

export interface NoteClientEnvironment {
  request(input: RequestInfo | URL, init?: RequestInit): Promise<Response>
  getSessionItem(key: string): string | null
  setSessionItem(key: string, value: string): void
  removeSessionItem(key: string): void
  appHeaders(): Record<string, string>
  currentURL(): string
  replaceURL(value: string): void
}

export class NoteTransportError extends Error {
  constructor(
    message: string,
    readonly kind: 'network' | 'http' | 'graphql' | 'result' | 'registration',
    readonly status?: number,
    readonly resultStatus?: string,
  ) {
    super(message)
  }
}

export function isProgressConflict(error: unknown): boolean {
  return error instanceof NoteTransportError && error.resultStatus === 'progress_conflict'
}

export class NoteGraphQLClient {
  private readonly environment: NoteClientEnvironment

  constructor(readonly mode: HostMode, environment?: NoteClientEnvironment) {
    this.environment = environment ?? browserEnvironment()
  }

  async initialize(): Promise<void> {
    if (this.mode !== 'cli-serve') return
    const url = new URL(this.environment.currentURL())
    const code = url.searchParams.get('code')
    if (!code) return
    url.searchParams.delete('code')
    this.environment.replaceURL(`${url.pathname}${url.search}${url.hash}`)
    const response = await this.environment.request('/note/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code, displayName: 'Kaiba Web' }),
    })
    const value = await parseJSON<{ credential?: { bearerToken?: string }; error?: string }>(response)
    const bearer = value.credential?.bearerToken
    if (!response.ok || !bearer) {
      throw new NoteTransportError(value.error ?? 'Registration failed.', 'registration', response.status)
    }
    this.environment.setSessionItem(bearerKey, bearer)
  }

  hasCredential(): boolean {
    return this.mode === 'riela-app' || Boolean(this.environment.getSessionItem(bearerKey))
  }

  /** Headers for the streaming note-events request (EventSource cannot send
   * an Authorization header, so the stream uses fetch with these). */
  streamHeaders(): Record<string, string> {
    const headers: Record<string, string> = { ...this.environment.appHeaders() }
    if (this.mode === 'cli-serve') {
      const bearer = this.environment.getSessionItem(bearerKey)
      if (bearer) headers.Authorization = `Bearer ${bearer}`
    }
    return headers
  }

  async tags(): Promise<NoteTag[]> {
    return this.queryValue<{ tags: QueryPayload<NoteTag[]> }, NoteTag[]>('Tags', `
      query Tags { tags { result { accepted status diagnostics } value { tagId name classId parentTagId isSystem createdAt } } }
    `, {}, (data) => data.tags)
  }

  async tagClasses(): Promise<NoteTagClass[]> {
    return this.queryValue<{ tagClasses: QueryPayload<NoteTagClass[]> }, NoteTagClass[]>('TagClasses', `
      query TagClasses { tagClasses { result { accepted status diagnostics } value { classId label description } } }
    `, {}, (data) => data.tagClasses)
  }

  async notebooks(
    offset: number,
    sort: NoteListSort,
    tagFilterIdGroups: string[][],
    limit = notebookPageLimit,
    created: { createdAfter?: string; createdBefore?: string } = {},
  ): Promise<Notebook[]> {
    const values = await this.queryValue<{ notebooks: QueryPayload<Notebook[]> }, Notebook[]>('Notebooks', `
      query Notebooks($limit: Int, $offset: Int, $sort: NoteListSort, $tagFilterIdGroups: [[String!]!], $createdAfter: String, $createdBefore: String) {
        notebooks(limit: $limit, offset: $offset, sort: $sort, tagFilterIdGroups: $tagFilterIdGroups, createdAfter: $createdAfter, createdBefore: $createdBefore) {
          result { accepted status diagnostics }
          value { notebookId title progress readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, {
      limit,
      offset,
      sort,
      tagFilterIdGroups,
      ...(created.createdAfter ? { createdAfter: created.createdAfter } : {}),
      ...(created.createdBefore ? { createdBefore: created.createdBefore } : {}),
    }, (data) => data.notebooks)
    return values.map(normalizeNotebook)
  }

  async notebook(notebookId: string): Promise<Notebook> {
    const value = await this.queryValue<{ notebook: QueryPayload<Notebook> }, Notebook>('Notebook', `
      query Notebook($notebookId: String!) {
        notebook(notebookId: $notebookId) {
          result { accepted status diagnostics }
          value { notebookId title progress readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId }, (data) => data.notebook)
    return normalizeNotebook(value)
  }

  async notes(notebookId: string, offset: number): Promise<Note[]> {
    return this.queryValue<{ notes: QueryPayload<Note[]> }, Note[]>('Notes', `
      query Notes($notebookId: String!, $limit: Int, $offset: Int) {
        notes(notebookId: $notebookId, limit: $limit, offset: $offset) {
          result { accepted status diagnostics }
          value { noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt metaJSON }
        }
      }
    `, { notebookId, limit: notebookPageLimit, offset }, (data) => data.notes)
  }

  /** The single-note read the reader and the Info tab share: unlike the list
   * query it carries the note's own tag assignments. */
  async note(noteId: string): Promise<Note> {
    return this.queryValue<{ note: QueryPayload<Note> }, Note>('Note', `
      query Note($noteId: String!) {
        note(noteId: $noteId) {
          result { accepted status diagnostics }
          value {
            noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt metaJSON
            tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } }
          }
        }
      }
    `, { noteId }, (data) => data.note)
  }

  /** Linked documents for the Links tab; `edgeKind` is the link kind the tab
   * groups by. Depth stays at one hop so the list is the note's own links. */
  async noteGraphNeighbors(noteId: string, limit = 20): Promise<NoteGraphNeighbor[]> {
    return this.queryValue<{ noteGraphNeighbors: QueryPayload<NoteGraphNeighbor[]> }, NoteGraphNeighbor[]>('NoteGraphNeighbors', `
      query NoteGraphNeighbors($noteIds: [String!]!, $depth: Int, $limit: Int) {
        noteGraphNeighbors(noteIds: $noteIds, depth: $depth, limit: $limit) {
          result { accepted status diagnostics }
          value {
            seedNoteId edgeKind weight hopCount pathNoteIds
            note { noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt }
          }
        }
      }
    `, { noteIds: [noteId], depth: 1, limit }, (data) => data.noteGraphNeighbors)
  }

  /** Stored memos for a note, oldest first (the server's own ordering). */
  async noteComments(noteId: string): Promise<NoteComment[]> {
    return this.queryValue<{ noteComments: QueryPayload<NoteComment[]> }, NoteComment[]>('NoteComments', `
      query NoteComments($noteId: String!) {
        noteComments(noteId: $noteId) {
          result { accepted status diagnostics }
          value { commentId noteId bodyMarkdown author createdAt }
        }
      }
    `, { noteId }, (data) => data.noteComments)
  }

  async addNoteComment(noteId: string, bodyMarkdown: string): Promise<NoteComment> {
    const payload = await this.mutation('AddNoteComment', `
      mutation AddNoteComment($input: AddNoteCommentInput!) {
        addNoteComment(input: $input) {
          result { accepted status diagnostics }
          comment { commentId noteId bodyMarkdown author createdAt }
        }
      }
    `, { input: { noteId, bodyMarkdown, author: 'kaiba-web' } }, 'addNoteComment')
    if (!payload.comment) throw new NoteTransportError('The server did not return the memo.', 'result')
    return payload.comment
  }

  async noteConversations(noteId: string, limit = 50): Promise<AgentConversation[]> {
    return this.queryValue<{ noteConversations: QueryPayload<AgentConversation[]> }, AgentConversation[]>('NoteConversations', `
      query NoteConversations($noteId: String!, $limit: Int) {
        noteConversations(noteId: $noteId, limit: $limit) {
          result { accepted status diagnostics }
          value { notebookId title updatedAt turnCount subjectNoteId }
        }
      }
    `, { noteId, limit }, (data) => data.noteConversations)
  }

  /** Persists the user turn. The reply is asynchronous: `agentStatus` reports
   * whether an agent runtime accepted it, and the note events feed delivers the
   * completion for the conversation notebook. */
  async sendAgentChatMessage(input: {
    subjectNoteId: string
    conversationNotebookId?: string
    userMarkdown: string
    idempotencyKey?: string
  }): Promise<AgentChatMessageResult> {
    const data = await this.request<{ sendAgentChatMessage: AgentChatMessageResult & { result: ControlResult } }>('SendAgentChatMessage', `
      mutation SendAgentChatMessage($input: SendAgentChatMessageInput!) {
        sendAgentChatMessage(input: $input) {
          result { accepted status diagnostics }
          conversationNotebookId
          turnNoteId
          agentStatus
        }
      }
    `, {
      input: {
        subjectNoteId: input.subjectNoteId,
        ...(input.conversationNotebookId ? { conversationNotebookId: input.conversationNotebookId } : {}),
        userMarkdown: input.userMarkdown,
        ...(input.idempotencyKey ? { idempotencyKey: input.idempotencyKey } : {}),
      },
    })
    const payload = data.sendAgentChatMessage
    if (!payload) throw new NoteTransportError('GraphQL response omitted sendAgentChatMessage.', 'graphql')
    ensureAccepted(payload.result)
    return {
      conversationNotebookId: payload.conversationNotebookId ?? null,
      turnNoteId: payload.turnNoteId ?? null,
      agentStatus: payload.agentStatus,
    }
  }

  /** Queues AI tag extraction for one note or a whole notebook; the returned
   * status is "queued" or "agent-unavailable". */
  async requestTagExtraction(subject: { noteId: string } | { notebookId: string }): Promise<string> {
    const data = await this.request<{ requestTagExtraction: { result: ControlResult; status: string } }>('RequestTagExtraction', `
      mutation RequestTagExtraction($input: RequestTagExtractionInput!) {
        requestTagExtraction(input: $input) {
          result { accepted status diagnostics }
          status
        }
      }
    `, { input: subject })
    const payload = data.requestTagExtraction
    if (!payload) throw new NoteTransportError('GraphQL response omitted requestTagExtraction.', 'graphql')
    ensureAccepted(payload.result)
    return payload.status
  }

  async defineFolder(name: string, classId: string, parentTagId?: string): Promise<NoteTag> {
    const payload = await this.mutation('DefineFolder', `
      mutation DefineFolder($input: DefineNoteTagInput!) {
        defineNoteTag(input: $input) {
          result { accepted status diagnostics }
          tag { tagId name classId parentTagId isSystem createdAt }
        }
      }
    `, { input: { name, classId, ...(parentTagId ? { parentTagId } : {}), createOnly: true } }, 'defineNoteTag')
    if (!payload.tag) throw new NoteTransportError('The server did not return the created folder.', 'result')
    return payload.tag
  }

  async applyTagById(notebookId: string, tagId: string): Promise<Notebook> {
    return this.notebookMutation('ApplyNotebookTagIds', `
      mutation ApplyNotebookTagIds($input: ApplyNotebookTagIdsInput!) {
        applyNotebookTagIds(input: $input) {
          result { accepted status diagnostics }
          notebook { notebookId title progress readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { input: { notebookId, tagIds: [tagId], provenance: 'human', assignedBy: 'kaiba-web' } }, 'applyNotebookTagIds')
  }

  async removeTagById(notebookId: string, tagId: string): Promise<Notebook> {
    return this.notebookMutation('RemoveNotebookTagById', `
      mutation RemoveNotebookTagById($notebookId: String!, $tagId: String!, $provenance: String) {
        removeNotebookTagById(notebookId: $notebookId, tagId: $tagId, provenance: $provenance) {
          result { accepted status diagnostics }
          notebook { notebookId title progress readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId, tagId, provenance: 'human' }, 'removeNotebookTagById')
  }

  async setProgress(notebookId: string, progress: string, expectedProgress?: string): Promise<Notebook> {
    return this.notebookMutation('SetProgress', `
      mutation SetProgress($notebookId: String!, $progress: String!, $expectedProgress: String) {
        setNotebookProgress(notebookId: $notebookId, progress: $progress, expectedProgress: $expectedProgress) {
          result { accepted status diagnostics }
          notebook { notebookId title progress readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId, progress, ...(expectedProgress ? { expectedProgress } : {}) }, 'setNotebookProgress')
  }

  async setNotebookReadOnly(notebookId: string, readOnly: boolean): Promise<Notebook> {
    return this.notebookMutation('SetNotebookReadOnly', `
      mutation SetNotebookReadOnly($notebookId: String!, $readOnly: Boolean!) {
        setNotebookReadOnly(notebookId: $notebookId, readOnly: $readOnly) {
          result { accepted status diagnostics }
          notebook { notebookId title progress readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId, readOnly }, 'setNotebookReadOnly')
  }

  async kanbanStatusSets(): Promise<KanbanStatusSet[]> {
    return this.queryValue<{ kanbanStatusSets: QueryPayload<KanbanStatusSet[]> }, KanbanStatusSet[]>('KanbanStatusSets', `
      query KanbanStatusSets { kanbanStatusSets { result { accepted status diagnostics } value { setId name isSystem statuses { statusId name category position } } } }
    `, {}, (data) => data.kanbanStatusSets)
  }

  async effectiveKanbanStatuses(): Promise<KanbanStatusSet> {
    return this.queryValue<{ effectiveKanbanStatuses: QueryPayload<KanbanStatusSet> }, KanbanStatusSet>('EffectiveKanbanStatuses', `
      query EffectiveKanbanStatuses { effectiveKanbanStatuses { result { accepted status diagnostics } value { setId name isSystem statuses { statusId name category position } } } }
    `, {}, (data) => data.effectiveKanbanStatuses)
  }

  async effectiveKanbanStatusesByTagId(tagId: string): Promise<KanbanStatusSet> {
    return this.queryValue<{ effectiveKanbanStatusesByTagId: QueryPayload<KanbanStatusSet> }, KanbanStatusSet>('EffectiveKanbanStatusesByTagId', `
      query EffectiveKanbanStatusesByTagId($tagId: String!) {
        effectiveKanbanStatusesByTagId(tagId: $tagId) {
          result { accepted status diagnostics }
          value { setId name isSystem statuses { statusId name category position } }
        }
      }
    `, { tagId }, (data) => data.effectiveKanbanStatusesByTagId)
  }

  async createKanbanStatusSet(name: string, statuses: Array<{ name: string; category: string }>): Promise<KanbanStatusSet> {
    return this.queryValue<{ createKanbanStatusSet: QueryPayload<KanbanStatusSet> }, KanbanStatusSet>('CreateKanbanStatusSet', `
      mutation CreateKanbanStatusSet($name: String!, $statuses: [KanbanStatusInput!]!) {
        createKanbanStatusSet(name: $name, statuses: $statuses) {
          result { accepted status diagnostics }
          value { setId name isSystem statuses { statusId name category position } }
        }
      }
    `, { name, statuses }, (data) => data.createKanbanStatusSet)
  }

  async updateKanbanStatusSet(
    setId: string,
    statuses: Array<{ statusId?: string; name: string; category: string }>,
    reassignments: Array<{ removedName: string; reassignTo: string }> = [],
  ): Promise<KanbanStatusSet> {
    return this.queryValue<{ updateKanbanStatusSet: QueryPayload<KanbanStatusSet> }, KanbanStatusSet>('UpdateKanbanStatusSet', `
      mutation UpdateKanbanStatusSet($setId: String!, $statuses: [KanbanStatusInput!]!, $reassignments: [KanbanStatusReassignmentInput!]) {
        updateKanbanStatusSet(setId: $setId, statuses: $statuses, reassignments: $reassignments) {
          result { accepted status diagnostics }
          value { setId name isSystem statuses { statusId name category position } }
        }
      }
    `, { setId, statuses, reassignments }, (data) => data.updateKanbanStatusSet)
  }

  async deleteKanbanStatusSet(setId: string): Promise<void> {
    const data = await this.request<{ deleteKanbanStatusSet: { accepted: boolean; status: string; diagnostics: string[] } }>('DeleteKanbanStatusSet', `
      mutation DeleteKanbanStatusSet($setId: String!) {
        deleteKanbanStatusSet(setId: $setId) { accepted status diagnostics }
      }
    `, { setId })
    ensureAccepted(data.deleteKanbanStatusSet)
  }

  async assignKanbanStatusSetByTagId(tagId: string, setId: string | null): Promise<NoteTag> {
    const payload = await this.mutation('AssignKanbanStatusSetByTagId', `
      mutation AssignKanbanStatusSetByTagId($tagId: String!, $setId: String) {
        assignKanbanStatusSetByTagId(tagId: $tagId, setId: $setId) {
          result { accepted status diagnostics }
          tag { tagId name classId parentTagId statusSetId isSystem createdAt }
        }
      }
    `, { tagId, setId }, 'assignKanbanStatusSetByTagId')
    if (!payload.tag) throw new NoteTransportError('The server did not return the updated tag.', 'result')
    return payload.tag
  }

  async searchNotes(input: {
    query: string
    tagFilter?: string[]
    classFilter?: string[]
    sort?: string
    createdAfter?: string
    createdBefore?: string
    includeLinked?: boolean
    limit?: number
    offset?: number
  }): Promise<NoteSearchResult[]> {
    return this.queryValue<{ searchNotes: QueryPayload<NoteSearchResult[]> }, NoteSearchResult[]>('SearchNotes', `
      query SearchNotes($query: String!, $tagFilter: [String!], $classFilter: [String!], $sort: NoteListSort, $createdAfter: String, $createdBefore: String, $includeLinked: Boolean, $limit: Int, $offset: Int) {
        searchNotes(query: $query, tagFilter: $tagFilter, classFilter: $classFilter, sort: $sort, createdAfter: $createdAfter, createdBefore: $createdBefore, includeLinked: $includeLinked, limit: $limit, offset: $offset) {
          result { accepted status diagnostics }
          value { snippet rank isLinkedNeighbor note { noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt } matchedTags { tagId name classId parentTagId isSystem createdAt } }
        }
      }
    `, {
      query: input.query,
      tagFilter: input.tagFilter ?? [],
      classFilter: input.classFilter ?? [],
      ...(input.sort ? { sort: input.sort } : {}),
      ...(input.createdAfter ? { createdAfter: input.createdAfter } : {}),
      ...(input.createdBefore ? { createdBefore: input.createdBefore } : {}),
      includeLinked: input.includeLinked ?? false,
      limit: input.limit ?? 20,
      offset: input.offset ?? 0,
    }, (data) => data.searchNotes)
  }

  async setNoteReadOnly(noteId: string, readOnly: boolean): Promise<Note> {
    const data = await this.request<{ setNoteReadOnly: { result: { accepted: boolean; status: string; diagnostics: string[] }; note?: Note | null } }>('SetNoteReadOnly', `
      mutation SetNoteReadOnly($noteId: String!, $readOnly: Boolean!) {
        setNoteReadOnly(noteId: $noteId, readOnly: $readOnly) {
          result { accepted status diagnostics }
          note { noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt }
        }
      }
    `, { noteId, readOnly })
    ensureAccepted(data.setNoteReadOnly.result)
    if (!data.setNoteReadOnly.note) throw new NoteTransportError('The server did not return the updated note.', 'result')
    return data.setNoteReadOnly.note
  }

  async applyNoteTag(noteId: string, tagName: string, classId?: string): Promise<void> {
    const data = await this.request<{ applyNoteTags: { result: { accepted: boolean; status: string; diagnostics: string[] } } }>('ApplyNoteTags', `
      mutation ApplyNoteTags($input: ApplyNoteTagsInput!) {
        applyNoteTags(input: $input) { result { accepted status diagnostics } }
      }
    `, { input: { noteId, tags: [{ name: tagName, ...(classId ? { classId } : {}) }], provenance: 'human', assignedBy: 'kaiba-web' } })
    ensureAccepted(data.applyNoteTags.result)
  }

  async removeNoteTag(noteId: string, tagName: string): Promise<void> {
    const data = await this.request<{ removeNoteTag: { result: { accepted: boolean; status: string; diagnostics: string[] } } }>('RemoveNoteTag', `
      mutation RemoveNoteTag($noteId: String!, $tagName: String!, $provenance: String) {
        removeNoteTag(noteId: $noteId, tagName: $tagName, provenance: $provenance) { result { accepted status diagnostics } }
      }
    `, { noteId, tagName, provenance: 'human' })
    ensureAccepted(data.removeNoteTag.result)
  }

  private async notebookMutation(
    operationName: string,
    query: string,
    variables: Record<string, unknown>,
    field: string,
  ): Promise<Notebook> {
    const payload = await this.mutation(operationName, query, variables, field)
    if (!payload.notebook) throw new NoteTransportError('The server did not return the notebook.', 'result')
    return normalizeNotebook(payload.notebook)
  }

  private async mutation(
    operationName: string,
    query: string,
    variables: Record<string, unknown>,
    field: string,
  ): Promise<MutationPayload> {
    const data = await this.request<Record<string, MutationPayload>>(operationName, query, variables)
    const payload = data[field]
    if (!payload) throw new NoteTransportError(`GraphQL response omitted ${field}.`, 'graphql')
    ensureAccepted(payload?.result)
    return payload
  }

  private async queryValue<Data, Value>(
    operationName: string,
    query: string,
    variables: Record<string, unknown>,
    select: (data: Data) => QueryPayload<Value>,
  ): Promise<Value> {
    const payload = select(await this.request<Data>(operationName, query, variables))
    ensureAccepted(payload.result)
    return payload.value
  }

  private async request<T>(
    operationName: string,
    query: string,
    variables: Record<string, unknown>,
  ): Promise<T> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json', ...this.environment.appHeaders() }
    if (this.mode === 'cli-serve') {
      // Send the bearer when registered; without one the request still goes
      // out so a `kaiba serve --allow-unauthenticated` host works, and an
      // auth-required host answers 401 with a registration hint.
      const bearer = this.environment.getSessionItem(bearerKey)
      if (bearer) headers.Authorization = `Bearer ${bearer}`
    }
    let response: Response
    try {
      response = await this.environment.request('/graphql', {
        method: 'POST',
        credentials: 'same-origin',
        headers,
        body: JSON.stringify({ query, variables, operationName }),
      })
    } catch (error) {
      throw new NoteTransportError(error instanceof Error ? error.message : String(error), 'network')
    }
    const envelope = await parseJSON<GraphQLEnvelope<T>>(response)
    if (response.status === 401 && this.mode === 'cli-serve') this.environment.removeSessionItem(bearerKey)
    if (!response.ok) {
      throw new NoteTransportError(envelope.error ?? `Request failed (${response.status}).`, 'http', response.status)
    }
    if (envelope.errors?.length) {
      throw new NoteTransportError(envelope.errors.map((error) => error.message).join('; '), 'graphql')
    }
    if (!envelope.data) throw new NoteTransportError('GraphQL response did not include data.', 'graphql')
    return envelope.data
  }
}

function normalizeNotebook(notebook: Notebook): Notebook {
  return { ...notebook, progress: String(notebook.progress), readOnly: Boolean(notebook.readOnly) }
}

function browserEnvironment(): NoteClientEnvironment {
  return {
    request: (input, init) => fetch(input, init),
    getSessionItem: (key) => sessionStorage.getItem(key),
    setSessionItem: (key, value) => sessionStorage.setItem(key, value),
    removeSessionItem: (key) => sessionStorage.removeItem(key),
    appHeaders: () => api.noteHeaders(),
    currentURL: () => window.location.href,
    replaceURL: (value) => history.replaceState(null, '', value),
  }
}

function ensureAccepted(result?: { accepted: boolean; diagnostics: string[]; status: string }): void {
  if (result?.accepted) return
  throw new NoteTransportError(
    result?.diagnostics.join('; ') || result?.status || 'Note operation failed.',
    'result',
    undefined,
    result?.status,
  )
}

async function parseJSON<T>(response: Response): Promise<T> {
  const text = await response.text()
  try {
    return JSON.parse(text) as T
  } catch {
    throw new NoteTransportError('The server returned invalid JSON.', 'http', response.status)
  }
}
