import { tool } from "ai";
import { z } from "zod";
import type { KaibaGraphQLClient } from "./graphql-client";

export function createKaibaTools(client: KaibaGraphQLClient) {
  return {
    searchNotes: tool({
      description: "Search Kaiba notes with deterministic full-text search.",
      inputSchema: z.object({
        query: z.string().min(1),
        limit: z.number().int().min(1).max(50).default(10),
      }),
      execute: ({ query, limit }) => client.searchNotes(query, limit),
    }),
    getNote: tool({
      description: "Read a Kaiba note by id.",
      inputSchema: z.object({ id: z.string().min(1) }),
      execute: ({ id }) => client.note(id),
    }),
    createNote: tool({
      description: "Create a note through Kaiba GraphQL.",
      inputSchema: z.object({
        notebookId: z.string().min(1),
        title: z.string().min(1).optional(),
        bodyMarkdown: z.string().min(1),
        tags: z.array(z.string().min(1)).optional(),
      }),
      execute: (input) => client.createNote({ ...input, provenance: "ai" }),
    }),
    updateNote: tool({
      description: "Update a note through Kaiba GraphQL.",
      inputSchema: z.object({
        id: z.string().min(1),
        title: z.string().min(1).optional(),
        bodyMarkdown: z.string().min(1).optional(),
      }),
      execute: (input) => client.updateNote(input),
    }),
    applyNoteTags: tool({
      description: "Attach normalized AI-provenance tags to a Kaiba note.",
      inputSchema: z.object({
        noteId: z.string().min(1),
        names: z.array(z.string().min(1)).min(1).max(30),
      }),
      execute: ({ noteId, names }) => client.applyNoteTags(noteId, names, "ai"),
    }),
    linkNotes: tool({
      description: "Create a directed link between two Kaiba notes.",
      inputSchema: z.object({
        sourceId: z.string().min(1),
        targetId: z.string().min(1),
      }),
      execute: ({ sourceId, targetId }) => client.linkNotes(sourceId, targetId),
    }),
  };
}

export type KaibaTools = ReturnType<typeof createKaibaTools>;
