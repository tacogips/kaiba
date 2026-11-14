import type { ToolSet } from "ai";
import { describe, expect, test } from "vitest";
import type { AiActionRouteInput } from "../src/config";
import type { AiExecutor } from "../src/executor";
import { KaibaAi } from "../src/runtime";

const note = {
  id: "note-1",
  notebookId: "default",
  title: "Workers",
  bodyMarkdown: "# Workers\nCloud platform",
  tags: [],
  linkedNoteIds: [],
};

class FakeExecutor implements AiExecutor {
  readonly vendors: string[] = [];

  async ocr(route: AiActionRouteInput): Promise<string> {
    this.vendors.push(route.vendor);
    return "OCR";
  }

  async tags(route: AiActionRouteInput): Promise<readonly string[]> {
    this.vendors.push(route.vendor);
    return ["cloudflare", "workers"];
  }

  async translate(route: AiActionRouteInput): Promise<string> {
    this.vendors.push(route.vendor);
    return "# ワーカー";
  }

  async title(route: AiActionRouteInput): Promise<string> {
    this.vendors.push(route.vendor);
    return "Cloudflare Workers";
  }

  async agent(
    route: AiActionRouteInput,
    _prompt: string,
    _tools: ToolSet,
    _maxSteps: number,
  ): Promise<{ readonly text: string; readonly toolCallCount: number }> {
    this.vendors.push(route.vendor);
    return { text: "done", toolCallCount: 1 };
  }
}

function graphqlFetch(
  input: RequestInfo | URL,
  init?: RequestInit,
): Promise<Response> {
  const request = new Request(input, init);
  return request.json().then((payload: { query: string }) => {
    if (payload.query.includes("ApplyNoteTags")) {
      return Response.json({
        data: {
          applyNoteTags: {
            ...note,
            tags: [
              { id: "tag-1", name: "cloudflare", provenance: "ai" },
              { id: "tag-2", name: "workers", provenance: "ai" },
            ],
          },
        },
      });
    }
    return Response.json({ data: { note } });
  });
}

describe("KaibaAi", () => {
  test("uses the action-specific vendor and writes tags through GraphQL", async () => {
    const executor = new FakeExecutor();
    const runtime = new KaibaAi({
      kaiba: { endpoint: "https://kaiba.test/graphql", fetch: graphqlFetch },
      routes: {
        tagging: {
          vendor: "anthropic",
          model: "tag-model",
          apiKey: "user-anthropic-key",
        },
        ocr: {
          vendor: "google",
          model: "ocr-model",
          apiKey: "user-google-key",
        },
      },
      executor,
    });

    const result = await runtime.tagNote({ noteId: note.id });

    expect(executor.vendors).toEqual(["anthropic"]);
    expect(result.note.tags).toMatchObject([
      { name: "cloudflare", provenance: "ai" },
      { name: "workers", provenance: "ai" },
    ]);
    expect(runtime.routing()).toMatchObject({
      ocr: { vendor: "google", keyPresent: true },
      tagging: { vendor: "anthropic", keyPresent: true },
    });
    expect(JSON.stringify(runtime.routing())).not.toContain("user-");
  });
});
