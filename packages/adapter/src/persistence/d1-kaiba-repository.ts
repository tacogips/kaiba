import type { KaibaRepository } from "@kaiba/application";
import type {
  Note,
  Notebook,
  NoteListFilter,
  NoteSearchResult,
  NoteTag,
  Provenance,
  Tag,
  UpdateNoteInput,
} from "@kaiba/domain";

type SqlValue = string | number | null | ArrayBuffer;

type NoteRow = {
  id: string;
  notebook_id: string;
  title: string;
  body_markdown: string;
  read_only: number;
  created_at: string;
  updated_at: string;
};

type NotebookRow = {
  id: string;
  title: string;
  read_only: number;
  created_at: string;
  updated_at: string;
};

type TagRow = {
  id: string;
  name: string;
  class_name: string | null;
  created_at: string;
};

type NoteTagRow = TagRow & { provenance: Provenance };
type LinkRow = { target_note_id: string };
type SearchRow = NoteRow & { snippet: string; rank: number };

export class D1KaibaRepository implements KaibaRepository {
  readonly #database: D1Database;

  constructor(database: D1Database) {
    this.#database = database;
  }

  async getNote(id: string): Promise<Note | null> {
    const row = await this.#database
      .prepare("SELECT * FROM notes WHERE id = ?")
      .bind(id)
      .first<NoteRow>();
    return row ? this.#hydrateNote(row) : null;
  }

  async listNotes(filter: NoteListFilter): Promise<readonly Note[]> {
    const { clauses, values } = tagAndNotebookClauses(filter);
    values.push(filter.limit ?? 50, filter.offset ?? 0);
    const result = await this.#database
      .prepare(
        `SELECT n.* FROM notes n ${where(clauses)}
         ORDER BY n.updated_at DESC LIMIT ? OFFSET ?`,
      )
      .bind(...values)
      .all<NoteRow>();
    return Promise.all(result.results.map((row) => this.#hydrateNote(row)));
  }

  async searchNotes(
    query: string,
    filter: NoteListFilter,
  ): Promise<readonly NoteSearchResult[]> {
    const { clauses, values } = tagAndNotebookClauses(filter);
    clauses.unshift("notes_fts MATCH ?");
    values.unshift(query);
    values.push(filter.limit ?? 50, filter.offset ?? 0);
    const result = await this.#database
      .prepare(
        `SELECT n.*, snippet(notes_fts, 1, '<mark>', '</mark>', '…', 24) AS snippet,
                bm25(notes_fts) AS rank
         FROM notes_fts JOIN notes n ON n.rowid = notes_fts.rowid
         ${where(clauses)} ORDER BY rank, n.updated_at DESC LIMIT ? OFFSET ?`,
      )
      .bind(...values)
      .all<SearchRow>();
    return Promise.all(
      result.results.map(async (row) => ({
        note: await this.#hydrateNote(row),
        snippet: row.snippet,
        rank: row.rank,
      })),
    );
  }

  async createNote(note: Note): Promise<void> {
    await this.#database
      .prepare(
        `INSERT INTO notes
         (id, notebook_id, title, body_markdown, read_only, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        note.id,
        note.notebookId,
        note.title,
        note.bodyMarkdown,
        note.readOnly ? 1 : 0,
        note.createdAt,
        note.updatedAt,
      )
      .run();
  }

  async updateNote(
    input: UpdateNoteInput & { readonly updatedAt: string },
  ): Promise<Note | null> {
    const current = await this.getNote(input.id);
    if (!current) return null;
    await this.#database
      .prepare(
        `UPDATE notes SET title = ?, body_markdown = ?, read_only = ?, updated_at = ?
         WHERE id = ?`,
      )
      .bind(
        input.title ?? current.title,
        input.bodyMarkdown ?? current.bodyMarkdown,
        (input.readOnly ?? current.readOnly) ? 1 : 0,
        input.updatedAt,
        input.id,
      )
      .run();
    return this.getNote(input.id);
  }

  async deleteNote(id: string): Promise<boolean> {
    const result = await this.#database
      .prepare("DELETE FROM notes WHERE id = ?")
      .bind(id)
      .run();
    return result.meta.changes > 0;
  }

  async getNotebook(id: string): Promise<Notebook | null> {
    const row = await this.#database
      .prepare("SELECT * FROM notebooks WHERE id = ?")
      .bind(id)
      .first<NotebookRow>();
    return row ? notebookFromRow(row) : null;
  }

  async listNotebooks(): Promise<readonly Notebook[]> {
    const result = await this.#database
      .prepare("SELECT * FROM notebooks ORDER BY title, id")
      .all<NotebookRow>();
    return result.results.map(notebookFromRow);
  }

  async createNotebook(notebook: Notebook): Promise<void> {
    await this.#database
      .prepare(
        `INSERT INTO notebooks (id, title, read_only, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?)`,
      )
      .bind(
        notebook.id,
        notebook.title,
        notebook.readOnly ? 1 : 0,
        notebook.createdAt,
        notebook.updatedAt,
      )
      .run();
  }

  async listTags(): Promise<readonly Tag[]> {
    const result = await this.#database
      .prepare("SELECT * FROM tags ORDER BY name, id")
      .all<TagRow>();
    return result.results.map(tagFromRow);
  }

  async applyNoteTags(
    noteId: string,
    names: readonly string[],
    provenance: Provenance,
  ): Promise<Note | null> {
    if (!(await this.getNote(noteId))) return null;
    for (const name of names) {
      let tag = await this.#database
        .prepare("SELECT * FROM tags WHERE name = ?")
        .bind(name)
        .first<TagRow>();
      if (!tag) {
        tag = {
          id: crypto.randomUUID(),
          name,
          class_name: null,
          created_at: new Date().toISOString(),
        };
        await this.#database
          .prepare(
            "INSERT OR IGNORE INTO tags (id, name, class_name, created_at) VALUES (?, ?, ?, ?)",
          )
          .bind(tag.id, tag.name, tag.class_name, tag.created_at)
          .run();
        tag =
          (await this.#database
            .prepare("SELECT * FROM tags WHERE name = ?")
            .bind(name)
            .first<TagRow>()) ?? tag;
      }
      await this.#database
        .prepare(
          `INSERT INTO note_tags (note_id, tag_id, provenance)
           VALUES (?, ?, ?)
           ON CONFLICT(note_id, tag_id) DO UPDATE SET provenance = excluded.provenance`,
        )
        .bind(noteId, tag.id, provenance)
        .run();
    }
    return this.getNote(noteId);
  }

  async removeNoteTag(noteId: string, name: string): Promise<Note | null> {
    if (!(await this.getNote(noteId))) return null;
    await this.#database
      .prepare(
        `DELETE FROM note_tags
         WHERE note_id = ? AND tag_id = (SELECT id FROM tags WHERE name = ?)`,
      )
      .bind(noteId, name)
      .run();
    return this.getNote(noteId);
  }

  async linkNotes(sourceId: string, targetId: string): Promise<Note | null> {
    if (!(await this.getNote(sourceId)) || !(await this.getNote(targetId)))
      return null;
    await this.#database
      .prepare(
        "INSERT OR IGNORE INTO note_links (source_note_id, target_note_id) VALUES (?, ?)",
      )
      .bind(sourceId, targetId)
      .run();
    return this.getNote(sourceId);
  }

  async unlinkNotes(sourceId: string, targetId: string): Promise<Note | null> {
    if (!(await this.getNote(sourceId))) return null;
    await this.#database
      .prepare(
        "DELETE FROM note_links WHERE source_note_id = ? AND target_note_id = ?",
      )
      .bind(sourceId, targetId)
      .run();
    return this.getNote(sourceId);
  }

  async #hydrateNote(row: NoteRow): Promise<Note> {
    const [tagResult, linkResult] = await Promise.all([
      this.#database
        .prepare(
          `SELECT t.*, nt.provenance FROM note_tags nt
           JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = ? ORDER BY t.name`,
        )
        .bind(row.id)
        .all<NoteTagRow>(),
      this.#database
        .prepare(
          "SELECT target_note_id FROM note_links WHERE source_note_id = ? ORDER BY target_note_id",
        )
        .bind(row.id)
        .all<LinkRow>(),
    ]);
    return {
      id: row.id,
      notebookId: row.notebook_id,
      title: row.title,
      bodyMarkdown: row.body_markdown,
      readOnly: row.read_only !== 0,
      tags: tagResult.results.map(noteTagFromRow),
      linkedNoteIds: linkResult.results.map((link) => link.target_note_id),
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }
}

function tagAndNotebookClauses(filter: NoteListFilter): {
  clauses: string[];
  values: SqlValue[];
} {
  const clauses: string[] = [];
  const values: SqlValue[] = [];
  if (filter.notebookId) {
    clauses.push("n.notebook_id = ?");
    values.push(filter.notebookId);
  }
  for (const name of filter.tagNames ?? []) {
    clauses.push(
      `EXISTS (SELECT 1 FROM note_tags nt JOIN tags t ON t.id = nt.tag_id
               WHERE nt.note_id = n.id AND t.name = ?)`,
    );
    values.push(name);
  }
  return { clauses, values };
}

function where(clauses: readonly string[]): string {
  return clauses.length === 0 ? "" : `WHERE ${clauses.join(" AND ")}`;
}

function notebookFromRow(row: NotebookRow): Notebook {
  return {
    id: row.id,
    title: row.title,
    readOnly: row.read_only !== 0,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function tagFromRow(row: TagRow): Tag {
  return {
    id: row.id,
    name: row.name,
    className: row.class_name,
    createdAt: row.created_at,
  };
}

function noteTagFromRow(row: NoteTagRow): NoteTag {
  return { ...tagFromRow(row), provenance: row.provenance };
}
