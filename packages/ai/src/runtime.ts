import type { ToolSet } from "ai";
import { AiActionRouter, type AiActionRouteInput } from "./config";
import { AiSdkExecutor, type AiExecutor } from "./executor";
import {
  KaibaGraphQLClient,
  type KaibaClientOptions,
  type KaibaNote,
} from "./graphql-client";
import { createKaibaTools } from "./tools";

export type KaibaAiOptions = {
  readonly kaiba: KaibaClientOptions;
  readonly routes: Partial<
    Record<
      "ocr" | "tagging" | "translation" | "agent" | "agentSearch" | "title",
      AiActionRouteInput
    >
  >;
  readonly executor?: AiExecutor | undefined;
};

export class KaibaAi {
  readonly #client: KaibaGraphQLClient;
  readonly #router: AiActionRouter;
  readonly #executor: AiExecutor;

  constructor(options: KaibaAiOptions) {
    this.#client = new KaibaGraphQLClient(options.kaiba);
    this.#router = new AiActionRouter(options.routes);
    this.#executor = options.executor ?? new AiSdkExecutor();
  }

  routing() {
    return this.#router.redacted();
  }

  tools(): ToolSet {
    return createKaibaTools(this.#client);
  }

  ocr(image: Uint8Array, mediaType: string): Promise<string> {
    return this.#executor.ocr(this.#router.resolve("ocr"), image, mediaType);
  }

  async tagNote(input: {
    readonly noteId: string;
    readonly dryRun?: boolean | undefined;
  }): Promise<{ readonly tags: readonly string[]; readonly note: KaibaNote }> {
    const note = await this.#requiredNote(input.noteId);
    const tags = await this.#executor.tags(
      this.#router.resolve("tagging"),
      note.title,
      note.bodyMarkdown,
    );
    if (input.dryRun) return { tags, note };
    return {
      tags,
      note: await this.#client.applyNoteTags(note.id, tags, "ai"),
    };
  }

  async translateNote(input: {
    readonly noteId: string;
    readonly targetLanguage: string;
    readonly writeBack?: boolean | undefined;
  }): Promise<{ readonly bodyMarkdown: string; readonly note: KaibaNote }> {
    const note = await this.#requiredNote(input.noteId);
    const bodyMarkdown = await this.#executor.translate(
      this.#router.resolve("translation"),
      note.bodyMarkdown,
      input.targetLanguage,
    );
    if (!input.writeBack) return { bodyMarkdown, note };
    return {
      bodyMarkdown,
      note: await this.#client.updateNote({ id: note.id, bodyMarkdown }),
    };
  }

  async titleNote(input: {
    readonly noteId: string;
    readonly writeBack?: boolean | undefined;
  }): Promise<{ readonly title: string; readonly note: KaibaNote }> {
    const note = await this.#requiredNote(input.noteId);
    const title = await this.#executor.title(
      this.#router.resolve("title"),
      note.bodyMarkdown,
    );
    if (!input.writeBack) return { title, note };
    return {
      title,
      note: await this.#client.updateNote({ id: note.id, title }),
    };
  }

  agent(
    prompt: string,
    options: { readonly maxSteps?: number | undefined } = {},
  ): Promise<{ readonly text: string; readonly toolCallCount: number }> {
    return this.#executor.agent(
      this.#router.resolve("agent"),
      prompt,
      this.tools(),
      boundedSteps(options.maxSteps),
    );
  }

  agentSearch(
    prompt: string,
    options: { readonly maxSteps?: number | undefined } = {},
  ): Promise<{ readonly text: string; readonly toolCallCount: number }> {
    const allTools = createKaibaTools(this.#client);
    const tools = {
      searchNotes: allTools.searchNotes,
      getNote: allTools.getNote,
    };
    return this.#executor.agent(
      this.#router.resolve("agentSearch"),
      prompt,
      tools,
      boundedSteps(options.maxSteps),
    );
  }

  async #requiredNote(id: string): Promise<KaibaNote> {
    const note = await this.#client.note(id);
    if (!note) throw new Error(`Kaiba note '${id}' was not found`);
    return note;
  }
}

function boundedSteps(value?: number): number {
  return Math.min(Math.max(value ?? 6, 1), 12);
}
