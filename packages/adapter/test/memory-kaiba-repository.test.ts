import { KaibaService } from "@kaiba/application";
import type { Notebook } from "@kaiba/domain";
import { describe, expect, test } from "vitest";
import { MemoryKaibaRepository } from "../src/persistence/memory-kaiba-repository";

const notebook: Notebook = {
  id: "book-1",
  title: "Default",
  readOnly: false,
  createdAt: "2026-08-25T00:00:00.000Z",
  updatedAt: "2026-08-25T00:00:00.000Z",
};

describe("KaibaService with memory persistence", () => {
  test("creates, tags, searches, and links notes", async () => {
    let nextId = 0;
    const repository = new MemoryKaibaRepository({ notebooks: [notebook] });
    const service = new KaibaService({
      repository,
      ids: { generate: () => `note-${++nextId}` },
      clock: { now: () => new Date("2026-08-25T01:00:00.000Z") },
    });

    const first = await service.createNote({
      notebookId: notebook.id,
      bodyMarkdown: "# Cloudflare plan\nUse D1.",
      tags: ["Architecture"],
      provenance: "ai",
    });
    const second = await service.createNote({
      notebookId: notebook.id,
      bodyMarkdown: "# SDK plan\nUse user keys.",
    });
    const linked = await service.linkNotes(first.id, second.id);

    expect(first.title).toBe("Cloudflare plan");
    expect(first.tags).toMatchObject([
      { name: "architecture", provenance: "ai" },
    ]);
    expect(linked.linkedNoteIds).toEqual([second.id]);
    expect(await service.searchNotes("user keys")).toMatchObject([
      { note: { id: second.id } },
    ]);
  });
});
