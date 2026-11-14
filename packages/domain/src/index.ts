export type Provenance = "human" | "ai" | "system";

export type Tag = {
  readonly id: string;
  readonly name: string;
  readonly className: string | null;
  readonly createdAt: string;
};

export type NoteTag = Tag & {
  readonly provenance: Provenance;
};

export type Notebook = {
  readonly id: string;
  readonly title: string;
  readonly readOnly: boolean;
  readonly createdAt: string;
  readonly updatedAt: string;
};

export type Note = {
  readonly id: string;
  readonly notebookId: string;
  readonly title: string;
  readonly bodyMarkdown: string;
  readonly readOnly: boolean;
  readonly tags: readonly NoteTag[];
  readonly linkedNoteIds: readonly string[];
  readonly createdAt: string;
  readonly updatedAt: string;
};

export type NoteSearchResult = {
  readonly note: Note;
  readonly snippet: string;
  readonly rank: number;
};

export type CreateNoteInput = {
  readonly notebookId: string;
  readonly bodyMarkdown: string;
  readonly title?: string | undefined;
  readonly tags?: readonly string[] | undefined;
  readonly provenance?: Provenance | undefined;
};

export type UpdateNoteInput = {
  readonly id: string;
  readonly bodyMarkdown?: string | undefined;
  readonly title?: string | undefined;
  readonly readOnly?: boolean | undefined;
};

export type NoteListFilter = {
  readonly notebookId?: string | undefined;
  readonly tagNames?: readonly string[] | undefined;
  readonly limit?: number | undefined;
  readonly offset?: number | undefined;
};

export function deriveTitle(bodyMarkdown: string): string {
  for (const line of bodyMarkdown.split("\n")) {
    if (line.startsWith("# ")) {
      const heading = line.slice(2).trim();
      if (heading.length > 0) return heading;
    }
  }
  const firstContent = bodyMarkdown
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line.length > 0);
  return firstContent?.slice(0, 120) ?? "Untitled";
}

export function normalizeTagName(value: string): string {
  return value.trim().toLocaleLowerCase().replaceAll(/\s+/g, "-");
}
