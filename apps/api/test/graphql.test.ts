import { MemoryKaibaRepository } from "@kaiba/adapter";
import { describe, expect, test } from "vitest";
import { createKaibaGraphQLServer } from "../src/server";

async function execute(query: string, variables?: Record<string, unknown>) {
  const repository = new MemoryKaibaRepository();
  const server = createKaibaGraphQLServer(repository);
  const response = await server.fetch(
    new Request("http://kaiba.test/graphql", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query, variables }),
    }),
  );
  return response.json() as Promise<{
    readonly data?: Record<string, unknown>;
    readonly errors?: readonly { readonly message: string }[];
  }>;
}

describe("Kaiba GraphQL API", () => {
  test("operates notebooks, notes, tags, and search without AI", async () => {
    const repository = new MemoryKaibaRepository();
    const server = createKaibaGraphQLServer(repository);
    const request = async (
      query: string,
      variables?: Record<string, unknown>,
    ) => {
      const response = await server.fetch(
        new Request("http://kaiba.test/graphql", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ query, variables }),
        }),
      );
      return response.json() as Promise<{ data: Record<string, unknown> }>;
    };

    const createdBook = await request(
      "mutation($title: String!) { createNotebook(title: $title) { id title } }",
      { title: "Research" },
    );
    const notebookId = (createdBook.data["createNotebook"] as { id: string })
      .id;
    const createdNote = await request(
      `mutation($input: CreateNoteInput!) {
        createNote(input: $input) { id title tags { name provenance } }
      }`,
      {
        input: {
          notebookId,
          bodyMarkdown: "# Workers\nD1-backed notes",
          tags: ["Cloudflare"],
          provenance: "ai",
        },
      },
    );
    const note = createdNote.data["createNote"] as {
      id: string;
      title: string;
      tags: readonly { name: string; provenance: string }[];
    };
    expect(note).toMatchObject({
      title: "Workers",
      tags: [{ name: "cloudflare", provenance: "ai" }],
    });

    const searched = await request(
      'query { searchNotes(query: "D1-backed") { note { id } snippet } }',
    );
    expect(searched.data["searchNotes"]).toMatchObject([
      { note: { id: note.id } },
    ]);
  });

  test("does not expose server-side AI fields", async () => {
    const result = await execute(
      'mutation { requestTagExtraction(noteId: "note-1") { status } }',
    );
    expect(result.data).toBeUndefined();
    expect(result.errors?.[0]?.message).toContain("requestTagExtraction");
  });
});
