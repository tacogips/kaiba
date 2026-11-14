import type { KaibaRepository } from "@kaiba/application";
import type {
  Note,
  Notebook,
  NoteListFilter,
  NoteSearchResult,
  Provenance,
  Tag,
  UpdateNoteInput,
} from "@kaiba/domain";

export class MemoryKaibaRepository implements KaibaRepository {
  readonly #notes = new Map<string, Note>();
  readonly #notebooks = new Map<string, Notebook>();
  readonly #tags = new Map<string, Tag>();

  constructor(
    seed: {
      readonly notebooks?: readonly Notebook[];
      readonly notes?: readonly Note[];
    } = {},
  ) {
    for (const notebook of seed.notebooks ?? [])
      this.#notebooks.set(notebook.id, notebook);
    for (const note of seed.notes ?? []) {
      this.#notes.set(note.id, note);
      for (const tag of note.tags) this.#tags.set(tag.name, tag);
    }
  }

  async getNote(id: string): Promise<Note | null> {
    return this.#notes.get(id) ?? null;
  }

  async listNotes(filter: NoteListFilter): Promise<readonly Note[]> {
    const tagNames = new Set(filter.tagNames ?? []);
    return [...this.#notes.values()]
      .filter(
        (note) => !filter.notebookId || note.notebookId === filter.notebookId,
      )
      .filter(
        (note) =>
          tagNames.size === 0 ||
          [...tagNames].every((name) =>
            note.tags.some((tag) => tag.name === name),
          ),
      )
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
      .slice(filter.offset ?? 0, (filter.offset ?? 0) + (filter.limit ?? 50));
  }

  async searchNotes(
    query: string,
    filter: NoteListFilter,
  ): Promise<readonly NoteSearchResult[]> {
    const lowered = query.toLocaleLowerCase();
    const notes = await this.listNotes({ ...filter, limit: 10_000, offset: 0 });
    return notes
      .filter((note) =>
        `${note.title}\n${note.bodyMarkdown}`
          .toLocaleLowerCase()
          .includes(lowered),
      )
      .slice(filter.offset ?? 0, (filter.offset ?? 0) + (filter.limit ?? 50))
      .map((note, index) => ({
        note,
        snippet: note.bodyMarkdown.slice(0, 240),
        rank: index,
      }));
  }

  async createNote(note: Note): Promise<void> {
    if (this.#notes.has(note.id)) throw new Error("note already exists");
    this.#notes.set(note.id, note);
  }

  async updateNote(
    input: UpdateNoteInput & { readonly updatedAt: string },
  ): Promise<Note | null> {
    const current = this.#notes.get(input.id);
    if (!current) return null;
    const note: Note = {
      ...current,
      ...(input.bodyMarkdown === undefined
        ? {}
        : { bodyMarkdown: input.bodyMarkdown }),
      ...(input.title === undefined ? {} : { title: input.title }),
      ...(input.readOnly === undefined ? {} : { readOnly: input.readOnly }),
      updatedAt: input.updatedAt,
    };
    this.#notes.set(note.id, note);
    return note;
  }

  async deleteNote(id: string): Promise<boolean> {
    const deleted = this.#notes.delete(id);
    if (deleted) {
      for (const [noteId, note] of this.#notes) {
        if (note.linkedNoteIds.includes(id)) {
          this.#notes.set(noteId, {
            ...note,
            linkedNoteIds: note.linkedNoteIds.filter((value) => value !== id),
          });
        }
      }
    }
    return deleted;
  }

  async getNotebook(id: string): Promise<Notebook | null> {
    return this.#notebooks.get(id) ?? null;
  }

  async listNotebooks(): Promise<readonly Notebook[]> {
    return [...this.#notebooks.values()].sort((left, right) =>
      left.title.localeCompare(right.title),
    );
  }

  async createNotebook(notebook: Notebook): Promise<void> {
    if (this.#notebooks.has(notebook.id))
      throw new Error("notebook already exists");
    this.#notebooks.set(notebook.id, notebook);
  }

  async listTags(): Promise<readonly Tag[]> {
    return [...this.#tags.values()].sort((left, right) =>
      left.name.localeCompare(right.name),
    );
  }

  async applyNoteTags(
    noteId: string,
    names: readonly string[],
    provenance: Provenance,
  ): Promise<Note | null> {
    const current = this.#notes.get(noteId);
    if (!current) return null;
    const assignments = [...current.tags];
    for (const name of names) {
      let tag = this.#tags.get(name);
      if (!tag) {
        tag = {
          id: crypto.randomUUID(),
          name,
          className: null,
          createdAt: new Date().toISOString(),
        };
        this.#tags.set(name, tag);
      }
      const index = assignments.findIndex((value) => value.id === tag.id);
      const assignment = { ...tag, provenance };
      if (index === -1) assignments.push(assignment);
      else assignments[index] = assignment;
    }
    const note = { ...current, tags: assignments };
    this.#notes.set(noteId, note);
    return note;
  }

  async removeNoteTag(noteId: string, name: string): Promise<Note | null> {
    const current = this.#notes.get(noteId);
    if (!current) return null;
    const note = {
      ...current,
      tags: current.tags.filter((tag) => tag.name !== name),
    };
    this.#notes.set(noteId, note);
    return note;
  }

  async linkNotes(sourceId: string, targetId: string): Promise<Note | null> {
    const source = this.#notes.get(sourceId);
    if (!source || !this.#notes.has(targetId)) return null;
    if (source.linkedNoteIds.includes(targetId)) return source;
    const note = {
      ...source,
      linkedNoteIds: [...source.linkedNoteIds, targetId],
    };
    this.#notes.set(sourceId, note);
    return note;
  }

  async unlinkNotes(sourceId: string, targetId: string): Promise<Note | null> {
    const source = this.#notes.get(sourceId);
    if (!source) return null;
    const note = {
      ...source,
      linkedNoteIds: source.linkedNoteIds.filter((id) => id !== targetId),
    };
    this.#notes.set(sourceId, note);
    return note;
  }
}
