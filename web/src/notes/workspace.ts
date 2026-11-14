import { api } from '../api'
import type { Note, Notebook } from './types'

// REST client for the RielaApp-hosted note workspace API (/api/v1/notes/*).
// These operations mirror the native RielaNoteUIClient surface; they are only
// available when the web app is served by RielaApp (not `riela note serve`).

export interface NoteComment {
  commentId: string
  noteId: string
  author: string | null
  bodyMarkdown: string
  createdAt: string
}

export interface NoteLink {
  linkId: string
  fromNoteId: string
  toNoteId: string
  linkKind: string
  provenance: string | null
  createdAt: string
}

export interface NoteFileAttachment {
  attachmentId?: string
  fileId: string
  noteId?: string
  mediaType: string
  byteSize: number
  originalFilename: string | null
  createdAt: string
}

export interface NoteDetail {
  note: Note
  comments: NoteComment[]
  links: NoteLink[]
  linkedNotes: Record<string, Note>
  files: NoteFileAttachment[]
}

export interface NoteWindow {
  notes: Note[]
  startOffset: number
  hasEarlierNotes: boolean
  hasMoreNotes: boolean
}

export interface NoteLinkProposal {
  targetNote: Note
  linkKind: string
  reason: string
  source: string
}

export interface NoteRewriteDraft {
  rewrittenMarkdown: string
  summary: string | null
}

export interface NoteSelectionAnswer {
  answerMarkdown: string
  summary: string | null
}

export interface NoteAgentCitation {
  noteId: string
  title: string | null
  snippet: string | null
}

export interface NoteAgentTurn {
  userMarkdown: string
  assistantMarkdown: string
  citations: NoteAgentCitation[]
}

export interface NoteAgentSaveResult {
  notebookId: string
  noteIds: string[]
}

export interface NoteConfigProposal {
  requestMarkdown: string
  assistantMarkdown: string
  tagClass: { classId: string; label: string; description: string | null }
  tag: { name: string; classId: string | null }
  autoAction: {
    actionId: string
    trigger: string
    workflowId: string
    filterJSON: string | null
    enabled: boolean
    position: number
  }
  ingestionWorkflow: {
    workflowId: string
    notebookKindTag?: string | null
    translationEnabled?: boolean
  }
}

export interface NoteConfigApplyResult {
  tagClass: unknown
  tag: unknown
  autoAction: unknown
  workflowScaffold: { workflowId: string; workflowRoot: string; workflowPath: string }
}

export interface NoteExpansionSession {
  sourceNotebookId: string
  conversationNotebookId: string
  initialNoteId: string
  compactSummaryMarkdown: string
  sourceNoteIds: string[]
}

export interface NoteExpansionAnswer {
  answerMarkdown: string
  summary?: string | null
}

interface DetailEnvelope { detail: NoteDetail }

export function noteFileURL(fileId: string): string {
  return `/api/v1/notes/files/${encodeURIComponent(fileId)}`
}

export class NoteWorkspaceClient {
  constructor(private readonly profileName: () => string) {}

  private body(extra: Record<string, unknown> = {}): Record<string, unknown> {
    return { expectedProfile: this.profileName(), ...extra }
  }

  async noteDetail(noteId: string): Promise<NoteDetail> {
    const value = await api.get<DetailEnvelope & { revision?: number }>(
      `/api/v1/notes/${encodeURIComponent(noteId)}/detail`,
    )
    return value.detail
  }

  async firstNote(notebookId: string): Promise<NoteDetail | null> {
    const value = await api.get<{ detail: NoteDetail | null; revision?: number }>(
      `/api/v1/notes/notebooks/${encodeURIComponent(notebookId)}/first-note`,
    )
    return value.detail
  }

  async notesWindow(noteId: string, pageSize: number): Promise<NoteWindow> {
    return api.get<NoteWindow & { revision?: number }>(
      `/api/v1/notes/${encodeURIComponent(noteId)}/window?pageSize=${pageSize}`,
    )
  }

  async createMemo(bodyMarkdown: string): Promise<NoteDetail> {
    const value = await api.mutate<DetailEnvelope & { revision?: number }>(
      '/api/v1/notes/memos', 'POST', this.body({ bodyMarkdown }),
    )
    return value.detail
  }

  async createNote(notebookId: string, bodyMarkdown: string): Promise<NoteDetail> {
    const value = await api.mutate<DetailEnvelope & { revision?: number }>(
      `/api/v1/notes/notebooks/${encodeURIComponent(notebookId)}/notes`, 'POST', this.body({ bodyMarkdown }),
    )
    return value.detail
  }

  async setNotebookReadOnly(notebookId: string, readOnly: boolean): Promise<Notebook> {
    const value = await api.mutate<{ notebook: Notebook; revision?: number }>(
      `/api/v1/notes/notebooks/${encodeURIComponent(notebookId)}/read-only`,
      'POST',
      this.body({ readOnly }),
    )
    return value.notebook
  }

  async updateNoteBody(noteId: string, bodyMarkdown: string): Promise<NoteDetail> {
    const value = await api.mutate<DetailEnvelope & { revision?: number }>(
      `/api/v1/notes/${encodeURIComponent(noteId)}/body`, 'POST', this.body({ bodyMarkdown }),
    )
    return value.detail
  }

  async addComment(noteId: string, bodyMarkdown: string, author?: string): Promise<NoteDetail> {
    const value = await api.mutate<DetailEnvelope & { revision?: number }>(
      `/api/v1/notes/${encodeURIComponent(noteId)}/comments`, 'POST', this.body({ bodyMarkdown, author }),
    )
    return value.detail
  }

  async promoteComment(noteId: string, commentId: string): Promise<NoteDetail> {
    const value = await api.mutate<DetailEnvelope & { revision?: number }>(
      `/api/v1/notes/${encodeURIComponent(noteId)}/comments/${encodeURIComponent(commentId)}/promote`,
      'POST',
      this.body(),
    )
    return value.detail
  }

  async linkNote(noteId: string, targetNoteId: string, linkKind: string): Promise<NoteDetail> {
    const value = await api.mutate<DetailEnvelope & { revision?: number }>(
      `/api/v1/notes/${encodeURIComponent(noteId)}/links`, 'POST', this.body({ targetNoteId, linkKind }),
    )
    return value.detail
  }

  async linkProposals(noteId: string): Promise<NoteLinkProposal[]> {
    const value = await api.mutate<{ proposals: NoteLinkProposal[]; revision?: number }>(
      `/api/v1/notes/${encodeURIComponent(noteId)}/link-proposals`, 'POST', this.body(),
    )
    return value.proposals
  }

  async rewrite(
    noteId: string,
    input: {
      instruction: string
      bodyMarkdown: string
      selectedText?: string
      selectionStart?: number
      selectionEnd?: number
    },
  ): Promise<NoteRewriteDraft> {
    const value = await api.mutate<{ draft: NoteRewriteDraft; revision?: number }>(
      `/api/v1/notes/${encodeURIComponent(noteId)}/rewrite`, 'POST', this.body({ ...input }),
    )
    return value.draft
  }

  async selectionQuestion(
    noteId: string,
    input: {
      question: string
      bodyMarkdown: string
      selectedText: string
      selectionStart: number
      selectionEnd: number
    },
  ): Promise<NoteSelectionAnswer> {
    const value = await api.mutate<{ draft: NoteSelectionAnswer; revision?: number }>(
      `/api/v1/notes/${encodeURIComponent(noteId)}/selection-question`, 'POST', this.body({ ...input }),
    )
    return value.draft
  }

  async agentTurn(message: string, limit?: number): Promise<NoteAgentTurn> {
    const value = await api.mutate<{ turn: NoteAgentTurn; revision?: number }>(
      '/api/v1/notes/agent/turns', 'POST', this.body({ message, limit }),
    )
    return value.turn
  }

  async saveAgentConversation(title: string, turns: NoteAgentTurn[]): Promise<NoteAgentSaveResult> {
    return api.mutate<NoteAgentSaveResult & { revision?: number }>(
      '/api/v1/notes/agent/conversations', 'POST', this.body({ title, turns }),
    )
  }

  async appendAgentTurn(notebookId: string, turn: NoteAgentTurn): Promise<NoteAgentSaveResult> {
    return api.mutate<NoteAgentSaveResult & { revision?: number }>(
      `/api/v1/notes/agent/conversations/${encodeURIComponent(notebookId)}/turns`, 'POST', this.body({ turn }),
    )
  }

  async proposeConfigChange(message: string): Promise<NoteConfigProposal> {
    const value = await api.mutate<{ proposal: NoteConfigProposal; revision?: number }>(
      '/api/v1/notes/config-agent/proposals', 'POST', this.body({ message }),
    )
    return value.proposal
  }

  async applyConfigProposal(proposal: NoteConfigProposal): Promise<NoteConfigApplyResult> {
    return api.mutate<NoteConfigApplyResult & { revision?: number }>(
      '/api/v1/notes/config-agent/applications', 'POST', this.body({ proposal }),
    )
  }

  async prepareExpansion(notebookId: string): Promise<NoteExpansionSession> {
    return api.mutate<NoteExpansionSession & { revision?: number }>(
      `/api/v1/notes/notebooks/${encodeURIComponent(notebookId)}/expansion/prepare`, 'POST', this.body(),
    )
  }

  async expansionAnswer(
    notebookId: string,
    compactSummaryMarkdown: string,
    questionMarkdown: string,
  ): Promise<NoteExpansionAnswer> {
    const value = await api.mutate<{ answer: NoteExpansionAnswer; revision?: number }>(
      `/api/v1/notes/notebooks/${encodeURIComponent(notebookId)}/expansion/answers`,
      'POST',
      this.body({ compactSummaryMarkdown, questionMarkdown }),
    )
    return value.answer
  }

  async appendExpansionTurn(
    conversationNotebookId: string,
    input: { turnId: string; questionMarkdown: string; assistantMarkdown: string; sourceNoteIds: string[] },
  ): Promise<Note> {
    const value = await api.mutate<{ note: Note; revision?: number }>(
      `/api/v1/notes/notebooks/${encodeURIComponent(conversationNotebookId)}/expansion/turns`,
      'POST',
      this.body({ ...input }),
    )
    return value.note
  }
}
