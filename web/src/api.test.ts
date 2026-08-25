import { afterEach, describe, expect, test, vi } from "vitest";
import { listNotes } from "./api";

afterEach(() => vi.unstubAllGlobals());

describe("web GraphQL client", () => {
  test("sends the Kaiba bearer and returns notes", async () => {
    const request = vi.fn(
      async (_input: RequestInfo | URL, init?: RequestInit) => {
        expect(new Headers(init?.headers).get("authorization")).toBe(
          "Bearer kaiba-token",
        );
        return Response.json({
          data: {
            notes: [
              {
                id: "note-1",
                notebookId: "default",
                title: "Worker",
                bodyMarkdown: "# Worker",
                tags: [],
                linkedNoteIds: [],
              },
            ],
          },
        });
      },
    );
    vi.stubGlobal("fetch", request);

    const notes = await listNotes({
      endpoint: "https://kaiba.test/graphql",
      token: "kaiba-token",
    });

    expect(notes).toMatchObject([{ id: "note-1", title: "Worker" }]);
  });
});
