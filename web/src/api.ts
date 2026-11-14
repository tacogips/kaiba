import type { KaibaNote } from "@kaiba/ai";

export type ApiOptions = {
  readonly endpoint: string;
  readonly token?: string | undefined;
};

export async function listNotes(
  options: ApiOptions,
): Promise<readonly KaibaNote[]> {
  const data = await request<{ readonly notes: readonly KaibaNote[] }>(
    options,
    `query Notes {
      notes { id notebookId title bodyMarkdown tags { id name provenance } linkedNoteIds }
    }`,
  );
  return data.notes;
}

export async function createNote(
  options: ApiOptions,
  bodyMarkdown: string,
): Promise<KaibaNote> {
  const data = await request<{ readonly createNote: KaibaNote }>(
    options,
    `mutation CreateNote($input: CreateNoteInput!) {
      createNote(input: $input) {
        id notebookId title bodyMarkdown tags { id name provenance } linkedNoteIds
      }
    }`,
    { input: { notebookId: "default", bodyMarkdown } },
  );
  return data.createNote;
}

async function request<T>(
  options: ApiOptions,
  query: string,
  variables: Record<string, unknown> = {},
): Promise<T> {
  const response = await fetch(options.endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(options.token ? { authorization: `Bearer ${options.token}` } : {}),
    },
    body: JSON.stringify({ query, variables }),
  });
  const payload = (await response.json()) as {
    readonly data?: T | undefined;
    readonly errors?: readonly { readonly message: string }[] | undefined;
  };
  if (!response.ok || !payload.data) {
    throw new Error(
      payload.errors?.map((error) => error.message).join("; ") ||
        `GraphQL request failed (${response.status})`,
    );
  }
  return payload.data;
}
