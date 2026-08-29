import type { FileId, NoteId, NotebookId, TagClassId, TagId } from './ids'
import type {
  AgentChatMessageResult,
  AgentChatAttachmentInput,
  AgentModelsResult,
  AgentConversation,
  AgenticSearchResult,
  AgentReplyStreamPoll,
  ControlResult,
  GraphQLEnvelope,
  MutationPayload,
  Note,
  Notebook,
  NoteComment,
  NoteFileAttachment,
  NoteGraphNeighbor,
  NoteListSort,
  NoteSearchResult,
  NoteTag,
  NoteTagClass,
  QueryPayload,
  TagComment,
  TagDetail,
} from './types'
import { isTauriRuntime, serverCredentialStorageKey, serverRequest } from './serverEndpoint'

const bearerKey = serverCredentialStorageKey
export const notebookPageLimit = 200

export interface NoteClientEnvironment {
  request(input: RequestInfo | URL, init?: RequestInit): Promise<Response>
  getStoredItem(key: string): string | null
  setStoredItem(key: string, value: string): void
  removeStoredItem(key: string): void
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

export class NoteGraphQLClient {
  private readonly environment: NoteClientEnvironment

  constructor(environment?: NoteClientEnvironment) {
    this.environment = environment ?? browserEnvironment()
  }

  async initialize(): Promise<void> {
    const url = new URL(this.environment.currentURL())
    const code = url.searchParams.get('code')
    if (!code) return
    url.searchParams.delete('code')
    this.environment.replaceURL(`${url.pathname}${url.search}${url.hash}`)
    const response = await this.environment.request('/note/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code, displayName: isTauriRuntime() ? 'Kaiba App' : 'Kaiba Web' }),
    })
    const value = await parseJSON<{ credential?: { bearerToken?: string }; error?: string }>(response)
    const bearer = value.credential?.bearerToken
    if (!response.ok || !bearer) {
      throw new NoteTransportError(value.error ?? 'Registration failed.', 'registration', response.status)
    }
    this.environment.setStoredItem(bearerKey, bearer)
  }

  /** True once a credential is held, whether it came from a registration code
   * or was pasted into the login view. */
  hasCredential(): boolean {
    return Boolean(this.environment.getStoredItem(bearerKey))
  }

  /** Adopts a key issued by `kaiba client issue`. The server is the only
   * judge of validity, so this stores the value and lets the next request
   * answer 401 if it was wrong. */
  useCredential(token: string): void {
    const trimmed = token.trim()
    if (!trimmed) throw new NoteTransportError('An API key is required.', 'registration')
    this.environment.setStoredItem(bearerKey, trimmed)
  }

  clearCredential(): void {
    this.environment.removeStoredItem(bearerKey)
  }

  /** Headers for the streaming note-events request (EventSource cannot send
   * an Authorization header, so the stream uses fetch with these). */
  streamHeaders(): Record<string, string> {
    const headers: Record<string, string> = {}
    const bearer = this.environment.getStoredItem(bearerKey)
    if (bearer) headers.Authorization = `Bearer ${bearer}`
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
          value { notebookId title readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
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

  async notebook(notebookId: NotebookId): Promise<Notebook> {
    const value = await this.queryValue<{ notebook: QueryPayload<Notebook> }, Notebook>('Notebook', `
      query Notebook($notebookId: String!) {
        notebook(notebookId: $notebookId) {
          result { accepted status diagnostics }
          value { notebookId title readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId }, (data) => data.notebook)
    return normalizeNotebook(value)
  }

  /** Notebook page listing. Carries each note's tag assignments so the right
   * pane can aggregate deduped tags across the notebook without extra reads. */
  async notes(notebookId: NotebookId, offset: number): Promise<Note[]> {
    return this.queryValue<{ notes: QueryPayload<Note[]> }, Note[]>('Notes', `
      query Notes($notebookId: String!, $limit: Int, $offset: Int) {
        notes(notebookId: $notebookId, limit: $limit, offset: $offset) {
          result { accepted status diagnostics }
          value {
            noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt metaJSON
            tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } }
          }
        }
      }
    `, { notebookId, limit: notebookPageLimit, offset }, (data) => data.notes)
  }

  /** The single-note read the reader and the Info tab share: unlike the list
   * query it carries the note's own tag assignments. */
  async note(noteId: NoteId): Promise<Note> {
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
  async noteGraphNeighbors(noteId: NoteId, limit = 20): Promise<NoteGraphNeighbor[]> {
    return this.noteGraphNeighborsMany([noteId], limit)
  }

  /** Same one-hop link read for several seed notes at once (the notebook-wide
   * links aggregate). The graph traversal caps `limit` at 20 per request, so
   * callers chunk the seeds and merge. */
  async noteGraphNeighborsMany(noteIds: NoteId[], limit = 20): Promise<NoteGraphNeighbor[]> {
    if (noteIds.length === 0) return []
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
    `, { noteIds, depth: 1, limit }, (data) => data.noteGraphNeighbors)
  }

  /** Stored memos for a note, oldest first (the server's own ordering). */
  async noteComments(noteId: NoteId): Promise<NoteComment[]> {
    return this.queryValue<{ noteComments: QueryPayload<NoteComment[]> }, NoteComment[]>('NoteComments', `
      query NoteComments($noteId: String!) {
        noteComments(noteId: $noteId) {
          result { accepted status diagnostics }
          value { commentId noteId notebookId bodyMarkdown author createdAt }
        }
      }
    `, { noteId }, (data) => data.noteComments)
  }

  /** Files attached to a note. Page captures and extracted images of an
   * imported document arrive here with image/* media types. */
  async noteFiles(noteId: NoteId): Promise<NoteFileAttachment[]> {
    return this.queryValue<{ noteFiles: QueryPayload<NoteFileAttachment[]> }, NoteFileAttachment[]>('NoteFiles', `
      query NoteFiles($noteId: String!) {
        noteFiles(noteId: $noteId) {
          result { accepted status diagnostics }
          value { noteId role position file { fileId storageKind mediaType byteSize sha256 originalFilename createdAt } }
        }
      }
    `, { noteId }, (data) => data.noteFiles)
  }

  /** Raw bytes of an attached file. `<img src>` cannot send the bearer
   * header, so callers fetch a Blob and show it through an object URL. */
  async noteFileBlob(fileId: FileId): Promise<Blob> {
    let response: Response
    try {
      response = await this.environment.request(`/files/${encodeURIComponent(fileId)}`, {
        method: 'GET',
        credentials: 'same-origin',
        headers: this.streamHeaders(),
      })
    } catch (error) {
      throw new NoteTransportError(error instanceof Error ? error.message : String(error), 'network')
    }
    if (!response.ok) {
      throw new NoteTransportError(`File request failed (${response.status}).`, 'http', response.status)
    }
    return response.blob()
  }

  /** Cross-notebook tag detail: the tag, its class, aggregate counts and its
   * memo notebook id (null until one is created). */
  async tagDetail(tagId: TagId): Promise<TagDetail> {
    return this.queryValue<{ tagDetail: QueryPayload<TagDetail> }, TagDetail>('TagDetail', `
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId) {
          result { accepted status diagnostics }
          value {
            tag { tagId name classId parentTagId isSystem createdAt }
            tagClass { classId label description }
            noteCount notebookCount memoNotebookId
          }
        }
      }
    `, { tagId }, (data) => data.tagDetail)
  }

  /** The tag's memo history: memos of notes/notebooks carrying the tag
   * (descendants included), across all notebooks, newest first. */
  async tagComments(tagId: TagId, offset = 0, limit = 50): Promise<TagComment[]> {
    return this.queryValue<{ tagComments: QueryPayload<TagComment[]> }, TagComment[]>('TagComments', `
      query TagComments($tagId: String!, $limit: Int, $offset: Int) {
        tagComments(tagId: $tagId, limit: $limit, offset: $offset) {
          result { accepted status diagnostics }
          value {
            comment { commentId noteId notebookId bodyMarkdown author createdAt }
            noteTitle notebookTitle
          }
        }
      }
    `, { tagId, limit, offset }, (data) => data.tagComments)
  }

  /** Cross-notebook occurrences: every note carrying the tag (or a
   * descendant), newest first. */
  async notesByTag(tagName: string, offset = 0, limit = notebookPageLimit): Promise<Note[]> {
    return this.queryValue<{ notes: QueryPayload<Note[]> }, Note[]>('NotesByTag', `
      query NotesByTag($tagFilter: [String!], $limit: Int, $offset: Int) {
        notes(tagFilter: $tagFilter, limit: $limit, offset: $offset) {
          result { accepted status diagnostics }
          value {
            noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt
            tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } }
          }
        }
      }
    `, { tagFilter: [tagName], limit, offset }, (data) => data.notes)
  }

  /** Finds or creates the tag's memo/chat notebook. */
  async ensureTagMemoNotebook(tagId: TagId): Promise<Notebook> {
    return this.notebookMutation('EnsureTagMemoNotebook', `
      mutation EnsureTagMemoNotebook($tagId: String!) {
        ensureTagMemoNotebook(tagId: $tagId) {
          result { accepted status diagnostics }
          notebook { notebookId title readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { tagId }, 'ensureTagMemoNotebook')
  }

  /** Every memo in the notebook — note-anchored and notebook-level alike. */
  async notebookComments(notebookId: NotebookId): Promise<NoteComment[]> {
    return this.queryValue<{ notebookComments: QueryPayload<NoteComment[]> }, NoteComment[]>('NotebookComments', `
      query NotebookComments($notebookId: String!) {
        notebookComments(notebookId: $notebookId) {
          result { accepted status diagnostics }
          value { commentId noteId notebookId bodyMarkdown author createdAt }
        }
      }
    `, { notebookId }, (data) => data.notebookComments)
  }

  async addNoteComment(noteId: NoteId, bodyMarkdown: string): Promise<NoteComment> {
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

  /** A notebook-level memo (no note selected). */
  async addNotebookComment(notebookId: NotebookId, bodyMarkdown: string): Promise<NoteComment> {
    const payload = await this.mutation('AddNotebookComment', `
      mutation AddNotebookComment($input: AddNotebookCommentInput!) {
        addNotebookComment(input: $input) {
          result { accepted status diagnostics }
          comment { commentId noteId notebookId bodyMarkdown author createdAt }
        }
      }
    `, { input: { notebookId, bodyMarkdown, author: 'kaiba-web' } }, 'addNotebookComment')
    if (!payload.comment) throw new NoteTransportError('The server did not return the memo.', 'result')
    return payload.comment
  }

  async noteConversations(noteId: NoteId, limit = 50): Promise<AgentConversation[]> {
    return this.queryValue<{ noteConversations: QueryPayload<AgentConversation[]> }, AgentConversation[]>('NoteConversations', `
      query NoteConversations($noteId: String!, $limit: Int) {
        noteConversations(noteId: $noteId, limit: $limit) {
          result { accepted status diagnostics }
          value { notebookId title updatedAt turnCount subjectNoteId subjectNotebookId }
        }
      }
    `, { noteId, limit }, (data) => data.noteConversations)
  }

  /** Conversations whose subject is the whole notebook (no note selected). */
  async notebookConversations(notebookId: NotebookId, limit = 50): Promise<AgentConversation[]> {
    return this.queryValue<{ notebookConversations: QueryPayload<AgentConversation[]> }, AgentConversation[]>('NotebookConversations', `
      query NotebookConversations($notebookId: String!, $limit: Int) {
        notebookConversations(notebookId: $notebookId, limit: $limit) {
          result { accepted status diagnostics }
          value { notebookId title updatedAt turnCount subjectNoteId subjectNotebookId }
        }
      }
    `, { notebookId, limit }, (data) => data.notebookConversations)
  }

  /** Persists the user turn. The subject is a note or a whole notebook (a memo
   * thread with no note selected). The reply is asynchronous: `agentStatus`
   * reports whether an agent runtime accepted it, and the note events feed
   * (plus the agent reply stream) delivers the completion. */
  async sendAgentChatMessage(input: {
    subjectNoteId?: NoteId
    subjectNotebookId?: NotebookId
    conversationNotebookId?: NotebookId
    userMarkdown: string
    idempotencyKey?: string
    model?: string
    mode?: 'edit'
    attachments?: AgentChatAttachmentInput[]
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
        ...(input.subjectNoteId ? { subjectNoteId: input.subjectNoteId } : {}),
        ...(input.subjectNotebookId ? { subjectNotebookId: input.subjectNotebookId } : {}),
        ...(input.conversationNotebookId ? { conversationNotebookId: input.conversationNotebookId } : {}),
        userMarkdown: input.userMarkdown,
        ...(input.idempotencyKey ? { idempotencyKey: input.idempotencyKey } : {}),
        ...(input.model ? { model: input.model } : {}),
        ...(input.mode ? { mode: input.mode } : {}),
        ...(input.attachments?.length ? { attachments: input.attachments } : {}),
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

  async agentModels(): Promise<AgentModelsResult> {
    const data = await this.request<{ agentModels: AgentModelsResult & { result: ControlResult } }>('AgentModels', `
      query AgentModels {
        agentModels {
          result { accepted status diagnostics }
          models { modelId displayName description }
          discoveryAvailable
          configuredModel
        }
      }
    `, {})
    if (!data.agentModels) throw new NoteTransportError('GraphQL response omitted agentModels.', 'graphql')
    ensureAccepted(data.agentModels.result)
    return {
      models: data.agentModels.models,
      discoveryAvailable: data.agentModels.discoveryAvailable,
      configuredModel: data.agentModels.configuredModel ?? null,
    }
  }

  /** Queues AI tag extraction for one note or a whole notebook; the returned
   * status is "queued" or "agent-unavailable". */
  async requestTagExtraction(subject: { noteId: NoteId } | { notebookId: NotebookId }): Promise<string> {
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

  /** Queues an AI translation of a whole notebook into `targetLanguage`. The
   * pending translation notebook is created immediately; translated notes
   * arrive via the events feed. Status is "queued" or "agent-unavailable". */
  async requestNotebookTranslation(input: {
    notebookId: NotebookId
    targetLanguage: string
    title?: string
  }): Promise<{ translationNotebookId: NotebookId | null; status: string }> {
    const data = await this.request<{ requestNotebookTranslation: { result: ControlResult; translationNotebookId?: NotebookId | null; status: string } }>('RequestNotebookTranslation', `
      mutation RequestNotebookTranslation($input: RequestNotebookTranslationInput!) {
        requestNotebookTranslation(input: $input) {
          result { accepted status diagnostics }
          translationNotebookId
          status
        }
      }
    `, {
      input: {
        notebookId: input.notebookId,
        targetLanguage: input.targetLanguage,
        ...(input.title ? { title: input.title } : {}),
      },
    })
    const payload = data.requestNotebookTranslation
    if (!payload) throw new NoteTransportError('GraphQL response omitted requestNotebookTranslation.', 'graphql')
    ensureAccepted(payload.result)
    return { translationNotebookId: payload.translationNotebookId ?? null, status: payload.status }
  }

  /** The stored JSON document for an app setting key, or null when unset. */
  async appSetting(key: string): Promise<string | null> {
    const data = await this.request<{ appSetting: { result: ControlResult; key: string; valueJSON?: string | null } }>('AppSetting', `
      query AppSetting($key: String!) {
        appSetting(key: $key) { result { accepted status diagnostics } key valueJSON }
      }
    `, { key })
    if (!data.appSetting) throw new NoteTransportError('GraphQL response omitted appSetting.', 'graphql')
    ensureAccepted(data.appSetting.result)
    return data.appSetting.valueJSON ?? null
  }

  /** Stores an app setting document (whole-document replace). */
  async setAppSetting(key: string, valueJSON: string): Promise<void> {
    const data = await this.request<{ setAppSetting: { result: ControlResult } }>('SetAppSetting', `
      mutation SetAppSetting($input: SetAppSettingInput!) {
        setAppSetting(input: $input) { result { accepted status diagnostics } key valueJSON }
      }
    `, { input: { key, valueJSON } })
    if (!data.setAppSetting) throw new NoteTransportError('GraphQL response omitted setAppSetting.', 'graphql')
    ensureAccepted(data.setAppSetting.result)
  }

  async applyTagById(notebookId: NotebookId, tagId: TagId): Promise<Notebook> {
    return this.notebookMutation('ApplyNotebookTagIds', `
      mutation ApplyNotebookTagIds($input: ApplyNotebookTagIdsInput!) {
        applyNotebookTagIds(input: $input) {
          result { accepted status diagnostics }
          notebook { notebookId title readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { input: { notebookId, tagIds: [tagId], provenance: 'human', assignedBy: 'kaiba-web' } }, 'applyNotebookTagIds')
  }

  async removeTagById(notebookId: NotebookId, tagId: TagId): Promise<Notebook> {
    return this.notebookMutation('RemoveNotebookTagById', `
      mutation RemoveNotebookTagById($notebookId: String!, $tagId: String!, $provenance: String) {
        removeNotebookTagById(notebookId: $notebookId, tagId: $tagId, provenance: $provenance) {
          result { accepted status diagnostics }
          notebook { notebookId title readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId, tagId, provenance: 'human' }, 'removeNotebookTagById')
  }

  async setNotebookReadOnly(notebookId: NotebookId, readOnly: boolean): Promise<Notebook> {
    return this.notebookMutation('SetNotebookReadOnly', `
      mutation SetNotebookReadOnly($notebookId: String!, $readOnly: Boolean!) {
        setNotebookReadOnly(notebookId: $notebookId, readOnly: $readOnly) {
          result { accepted status diagnostics }
          notebook { notebookId title readOnly createdAt updatedAt firstNotePreview noteCount tags { provenance assignedBy deletable createdAt tag { tagId name classId parentTagId isSystem createdAt } } }
        }
      }
    `, { notebookId, readOnly }, 'setNotebookReadOnly')
  }

  async searchNotes(input: {
    query: string
    tagFilter?: string[]
    classFilter?: string[]
    notebookId?: NotebookId
    sort?: string
    createdAfter?: string
    createdBefore?: string
    includeLinked?: boolean
    limit?: number
    offset?: number
  }): Promise<NoteSearchResult[]> {
    return this.queryValue<{ searchNotes: QueryPayload<NoteSearchResult[]> }, NoteSearchResult[]>('SearchNotes', `
      query SearchNotes($query: String!, $tagFilter: [String!], $classFilter: [String!], $notebookId: String, $sort: NoteListSort, $createdAfter: String, $createdBefore: String, $includeLinked: Boolean, $limit: Int, $offset: Int) {
        searchNotes(query: $query, tagFilter: $tagFilter, classFilter: $classFilter, notebookId: $notebookId, sort: $sort, createdAfter: $createdAfter, createdBefore: $createdBefore, includeLinked: $includeLinked, limit: $limit, offset: $offset) {
          result { accepted status diagnostics }
          value { snippet rank isLinkedNeighbor note { noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt } matchedTags { tagId name classId parentTagId isSystem createdAt } }
        }
      }
    `, {
      query: input.query,
      tagFilter: input.tagFilter ?? [],
      classFilter: input.classFilter ?? [],
      ...(input.notebookId ? { notebookId: input.notebookId } : {}),
      ...(input.sort ? { sort: input.sort } : {}),
      ...(input.createdAfter ? { createdAfter: input.createdAfter } : {}),
      ...(input.createdBefore ? { createdBefore: input.createdBefore } : {}),
      includeLinked: input.includeLinked ?? false,
      limit: input.limit ?? 20,
      offset: input.offset ?? 0,
    }, (data) => data.searchNotes)
  }

  /** Agentic search: the configured agent answers the question, grounded in a
   * grep pass and (for command-running agents) its own kaiba CLI searches.
   * Slow by nature — expect seconds to minutes. */
  async agenticSearch(input: {
    query: string
    notebookId?: NotebookId
    limit?: number
  }): Promise<AgenticSearchResult> {
    const data = await this.request<{ agenticSearch: AgenticSearchResult & { result: ControlResult } }>('AgenticSearch', `
      query AgenticSearch($query: String!, $notebookId: String, $limit: Int) {
        agenticSearch(query: $query, notebookId: $notebookId, limit: $limit) {
          result { accepted status diagnostics }
          status
          answerMarkdown
        }
      }
    `, {
      query: input.query,
      ...(input.notebookId ? { notebookId: input.notebookId } : {}),
      limit: input.limit ?? 20,
    })
    const payload = data.agenticSearch
    if (!payload) throw new NoteTransportError('GraphQL response omitted agenticSearch.', 'graphql')
    ensureAccepted(payload.result)
    return { status: payload.status, answerMarkdown: payload.answerMarkdown ?? null }
  }

  /** One long poll of the agent reply chunk stream for a pending chat turn.
   * `cursor` is the number of chunks already seen. */
  async pollAgentReplyStream(
    turnNoteId: NoteId,
    cursor: number,
    timeoutMs = 25_000,
  ): Promise<AgentReplyStreamPoll> {
    const parameters = new URLSearchParams({
      turn: turnNoteId,
      cursor: String(cursor),
      timeoutMs: String(timeoutMs),
    })
    let response: Response
    try {
      response = await this.environment.request(`/note/agent-stream?${parameters.toString()}`, {
        method: 'GET',
        credentials: 'same-origin',
        headers: this.streamHeaders(),
      })
    } catch (error) {
      throw new NoteTransportError(error instanceof Error ? error.message : String(error), 'network')
    }
    const value = await parseJSON<Partial<AgentReplyStreamPoll> & { error?: string }>(response)
    if (!response.ok) {
      throw new NoteTransportError(value.error ?? `Stream poll failed (${response.status}).`, 'http', response.status)
    }
    return {
      cursor: typeof value.cursor === 'number' ? value.cursor : cursor,
      chunks: Array.isArray(value.chunks) ? value.chunks.filter((chunk): chunk is string => typeof chunk === 'string') : [],
      done: value.done === true,
      status: typeof value.status === 'string' ? value.status : null,
      message: typeof value.message === 'string' ? value.message : null,
    }
  }

  async applyNoteTag(noteId: NoteId, tagName: string, classId?: TagClassId): Promise<void> {
    const data = await this.request<{ applyNoteTags: { result: { accepted: boolean; status: string; diagnostics: string[] } } }>('ApplyNoteTags', `
      mutation ApplyNoteTags($input: ApplyNoteTagsInput!) {
        applyNoteTags(input: $input) { result { accepted status diagnostics } }
      }
    `, { input: { noteId, tags: [{ name: tagName, ...(classId ? { classId } : {}) }], provenance: 'human', assignedBy: 'kaiba-web' } })
    ensureAccepted(data.applyNoteTags.result)
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
    const headers: Record<string, string> = { 'Content-Type': 'application/json' }
    // Send the bearer when registered; without one the request still goes
    // out so a `kaiba serve --allow-unauthenticated` host works, and an
    // auth-required host answers 401 with a registration hint.
    const bearer = this.environment.getStoredItem(bearerKey)
    if (bearer) headers.Authorization = `Bearer ${bearer}`
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
    if (response.status === 401) this.environment.removeStoredItem(bearerKey)
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
  return { ...notebook, readOnly: Boolean(notebook.readOnly) }
}

// The credential lives in localStorage, not sessionStorage: a registration
// code is single-use, expires in 300 seconds and is printed only at server
// startup, so a per-tab credential would strand every new tab.
function browserEnvironment(): NoteClientEnvironment {
  return {
    request: serverRequest,
    getStoredItem: (key) => localStorage.getItem(key),
    setStoredItem: (key, value) => localStorage.setItem(key, value),
    removeStoredItem: (key) => localStorage.removeItem(key),
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
