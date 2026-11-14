import {
  deriveTitle,
  normalizeTagName,
  type CreateNoteInput,
  type Note,
  type Notebook,
  type NoteListFilter,
  type NoteSearchResult,
  type Provenance,
  type Tag,
  type UpdateNoteInput,
} from "@kaiba/domain";

export type Clock = { readonly now: () => Date };
export type IdGenerator = { readonly generate: () => string };

export interface KaibaRepository {
  getNote(id: string): Promise<Note | null>;
  listNotes(filter: NoteListFilter): Promise<readonly Note[]>;
  searchNotes(
    query: string,
    filter: NoteListFilter,
  ): Promise<readonly NoteSearchResult[]>;
  createNote(note: Note): Promise<void>;
  updateNote(
    input: UpdateNoteInput & { readonly updatedAt: string },
  ): Promise<Note | null>;
  deleteNote(id: string): Promise<boolean>;
  getNotebook(id: string): Promise<Notebook | null>;
  listNotebooks(): Promise<readonly Notebook[]>;
  createNotebook(notebook: Notebook): Promise<void>;
  listTags(): Promise<readonly Tag[]>;
  applyNoteTags(
    noteId: string,
    names: readonly string[],
    provenance: Provenance,
  ): Promise<Note | null>;
  removeNoteTag(noteId: string, name: string): Promise<Note | null>;
  linkNotes(sourceId: string, targetId: string): Promise<Note | null>;
  unlinkNotes(sourceId: string, targetId: string): Promise<Note | null>;
}

export class KaibaError extends Error {
  constructor(
    readonly code: "invalid_input" | "not_found" | "read_only" | "conflict",
    message: string,
  ) {
    super(message);
    this.name = "KaibaError";
  }
}

export type KaibaServiceDependencies = {
  readonly repository: KaibaRepository;
  readonly clock?: Clock | undefined;
  readonly ids?: IdGenerator | undefined;
};

const systemClock: Clock = { now: () => new Date() };
const uuidGenerator: IdGenerator = { generate: () => crypto.randomUUID() };

export class KaibaService {
  readonly #repository: KaibaRepository;
  readonly #clock: Clock;
  readonly #ids: IdGenerator;

  constructor(dependencies: KaibaServiceDependencies) {
    this.#repository = dependencies.repository;
    this.#clock = dependencies.clock ?? systemClock;
    this.#ids = dependencies.ids ?? uuidGenerator;
  }

  getNote(id: string): Promise<Note | null> {
    return this.#repository.getNote(requireText(id, "note id"));
  }

  listNotes(filter: NoteListFilter = {}): Promise<readonly Note[]> {
    return this.#repository.listNotes(normalizeFilter(filter));
  }

  searchNotes(
    query: string,
    filter: NoteListFilter = {},
  ): Promise<readonly NoteSearchResult[]> {
    return this.#repository.searchNotes(
      requireText(query, "search query"),
      normalizeFilter(filter),
    );
  }

  getNotebook(id: string): Promise<Notebook | null> {
    return this.#repository.getNotebook(requireText(id, "notebook id"));
  }

  listNotebooks(): Promise<readonly Notebook[]> {
    return this.#repository.listNotebooks();
  }

  listTags(): Promise<readonly Tag[]> {
    return this.#repository.listTags();
  }

  async createNotebook(title: string): Promise<Notebook> {
    const now = this.#clock.now().toISOString();
    const notebook: Notebook = {
      id: this.#ids.generate(),
      title: requireText(title, "notebook title"),
      readOnly: false,
      createdAt: now,
      updatedAt: now,
    };
    await this.#repository.createNotebook(notebook);
    return notebook;
  }

  async createNote(input: CreateNoteInput): Promise<Note> {
    const notebook = await this.#repository.getNotebook(
      requireText(input.notebookId, "notebook id"),
    );
    if (!notebook) throw new KaibaError("not_found", "notebook not found");
    if (notebook.readOnly)
      throw new KaibaError("read_only", "notebook is read-only");
    const bodyMarkdown = requireText(input.bodyMarkdown, "note body");
    const now = this.#clock.now().toISOString();
    const note: Note = {
      id: this.#ids.generate(),
      notebookId: notebook.id,
      title: input.title
        ? requireText(input.title, "note title")
        : deriveTitle(bodyMarkdown),
      bodyMarkdown,
      readOnly: false,
      tags: [],
      linkedNoteIds: [],
      createdAt: now,
      updatedAt: now,
    };
    await this.#repository.createNote(note);
    if (!input.tags || input.tags.length === 0) return note;
    return (
      (await this.#repository.applyNoteTags(
        note.id,
        normalizeTags(input.tags),
        input.provenance ?? "human",
      )) ?? note
    );
  }

  async updateNote(input: UpdateNoteInput): Promise<Note> {
    const current = await this.#repository.getNote(
      requireText(input.id, "note id"),
    );
    if (!current) throw new KaibaError("not_found", "note not found");
    if (current.readOnly && input.readOnly !== false) {
      throw new KaibaError("read_only", "note is read-only");
    }
    const updated = await this.#repository.updateNote({
      ...input,
      ...(input.bodyMarkdown === undefined
        ? {}
        : { bodyMarkdown: requireText(input.bodyMarkdown, "note body") }),
      ...(input.title === undefined
        ? {}
        : { title: requireText(input.title, "note title") }),
      updatedAt: this.#clock.now().toISOString(),
    });
    if (!updated) throw new KaibaError("not_found", "note not found");
    return updated;
  }

  async deleteNote(id: string): Promise<boolean> {
    return this.#repository.deleteNote(requireText(id, "note id"));
  }

  async applyNoteTags(
    noteId: string,
    names: readonly string[],
    provenance: Provenance,
  ): Promise<Note> {
    const note = await this.#repository.applyNoteTags(
      requireText(noteId, "note id"),
      normalizeTags(names),
      provenance,
    );
    if (!note) throw new KaibaError("not_found", "note not found");
    return note;
  }

  async removeNoteTag(noteId: string, name: string): Promise<Note> {
    const note = await this.#repository.removeNoteTag(
      requireText(noteId, "note id"),
      normalizeTagName(requireText(name, "tag name")),
    );
    if (!note) throw new KaibaError("not_found", "note not found");
    return note;
  }

  async linkNotes(sourceId: string, targetId: string): Promise<Note> {
    if (sourceId === targetId)
      throw new KaibaError("invalid_input", "a note cannot link to itself");
    const note = await this.#repository.linkNotes(sourceId, targetId);
    if (!note)
      throw new KaibaError("not_found", "source or target note not found");
    return note;
  }

  async unlinkNotes(sourceId: string, targetId: string): Promise<Note> {
    const note = await this.#repository.unlinkNotes(sourceId, targetId);
    if (!note) throw new KaibaError("not_found", "source note not found");
    return note;
  }
}

function requireText(value: string, label: string): string {
  const normalized = value.trim();
  if (normalized.length === 0)
    throw new KaibaError("invalid_input", `${label} is required`);
  return normalized;
}

function normalizeTags(values: readonly string[]): readonly string[] {
  const normalized = [
    ...new Set(
      values.map(normalizeTagName).filter((value) => value.length > 0),
    ),
  ];
  if (normalized.length === 0)
    throw new KaibaError("invalid_input", "at least one tag is required");
  return normalized;
}

function normalizeFilter(filter: NoteListFilter): NoteListFilter {
  return {
    ...(filter.notebookId
      ? { notebookId: requireText(filter.notebookId, "notebook id") }
      : {}),
    ...(filter.tagNames ? { tagNames: normalizeTags(filter.tagNames) } : {}),
    limit: Math.min(Math.max(filter.limit ?? 50, 1), 200),
    offset: Math.max(filter.offset ?? 0, 0),
  };
}

export type {
  CreateNoteInput,
  Note,
  Notebook,
  NoteListFilter,
  NoteSearchResult,
  Provenance,
  Tag,
  UpdateNoteInput,
} from "@kaiba/domain";
