export type KaibaClientOptions = {
  readonly endpoint: string;
  readonly token?: string | undefined;
  readonly fetch?: typeof globalThis.fetch | undefined;
};

export type KaibaTag = {
  readonly id: string;
  readonly name: string;
  readonly provenance: "human" | "ai" | "system";
};

export type KaibaNote = {
  readonly id: string;
  readonly notebookId: string;
  readonly title: string;
  readonly bodyMarkdown: string;
  readonly tags: readonly KaibaTag[];
  readonly linkedNoteIds: readonly string[];
};

export class KaibaGraphQLClient {
  readonly #endpoint: string;
  readonly #token: string | undefined;
  readonly #fetch: typeof globalThis.fetch;

  constructor(options: KaibaClientOptions) {
    this.#endpoint = options.endpoint;
    this.#token = options.token;
    this.#fetch = options.fetch ?? globalThis.fetch;
  }

  async note(id: string): Promise<KaibaNote | null> {
    const data = await this.#request<{ readonly note: KaibaNote | null }>(
      `query Note($id: ID!) {
        note(id: $id) { id notebookId title bodyMarkdown tags { id name provenance } linkedNoteIds }
      }`,
      { id },
    );
    return data.note;
  }

  async searchNotes(query: string, limit = 10): Promise<readonly KaibaNote[]> {
    const data = await this.#request<{
      readonly searchNotes: readonly { readonly note: KaibaNote }[];
    }>(
      `query SearchNotes($query: String!, $limit: Int!) {
        searchNotes(query: $query, filter: { limit: $limit }) {
          note { id notebookId title bodyMarkdown tags { id name provenance } linkedNoteIds }
        }
      }`,
      { query, limit },
    );
    return data.searchNotes.map((result) => result.note);
  }

  async createNote(input: {
    readonly notebookId: string;
    readonly title?: string | undefined;
    readonly bodyMarkdown: string;
    readonly tags?: readonly string[] | undefined;
    readonly provenance?: "human" | "ai" | "system" | undefined;
  }): Promise<KaibaNote> {
    const data = await this.#request<{ readonly createNote: KaibaNote }>(
      `mutation CreateNote($input: CreateNoteInput!) {
        createNote(input: $input) {
          id notebookId title bodyMarkdown tags { id name provenance } linkedNoteIds
        }
      }`,
      { input },
    );
    return data.createNote;
  }

  async updateNote(input: {
    readonly id: string;
    readonly title?: string | undefined;
    readonly bodyMarkdown?: string | undefined;
  }): Promise<KaibaNote> {
    const data = await this.#request<{ readonly updateNote: KaibaNote }>(
      `mutation UpdateNote($input: UpdateNoteInput!) {
        updateNote(input: $input) {
          id notebookId title bodyMarkdown tags { id name provenance } linkedNoteIds
        }
      }`,
      { input },
    );
    return data.updateNote;
  }

  async applyNoteTags(
    noteId: string,
    names: readonly string[],
    provenance: "human" | "ai" | "system" = "ai",
  ): Promise<KaibaNote> {
    const data = await this.#request<{ readonly applyNoteTags: KaibaNote }>(
      `mutation ApplyNoteTags($noteId: ID!, $names: [String!]!, $provenance: Provenance!) {
        applyNoteTags(noteId: $noteId, names: $names, provenance: $provenance) {
          id notebookId title bodyMarkdown tags { id name provenance } linkedNoteIds
        }
      }`,
      { noteId, names, provenance },
    );
    return data.applyNoteTags;
  }

  async linkNotes(sourceId: string, targetId: string): Promise<KaibaNote> {
    const data = await this.#request<{ readonly linkNotes: KaibaNote }>(
      `mutation LinkNotes($sourceId: ID!, $targetId: ID!) {
        linkNotes(sourceId: $sourceId, targetId: $targetId) {
          id notebookId title bodyMarkdown tags { id name provenance } linkedNoteIds
        }
      }`,
      { sourceId, targetId },
    );
    return data.linkNotes;
  }

  async #request<T>(
    query: string,
    variables: Record<string, unknown>,
  ): Promise<T> {
    const response = await this.#fetch(this.#endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(this.#token ? { authorization: `Bearer ${this.#token}` } : {}),
      },
      body: JSON.stringify({ query, variables }),
    });
    const payload = (await response.json()) as {
      readonly data?: T | undefined;
      readonly errors?:
        | readonly { readonly message?: string | undefined }[]
        | undefined;
    };
    if (!response.ok || !payload.data) {
      const message = payload.errors?.map((error) => error.message).join("; ");
      throw new Error(
        message || `Kaiba GraphQL request failed (${response.status})`,
      );
    }
    return payload.data;
  }
}
