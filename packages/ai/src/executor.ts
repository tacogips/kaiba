import { generateText, Output, stepCountIs, type ToolSet } from "ai";
import { z } from "zod";
import type { AiActionRouteInput } from "./config";
import { resolveLanguageModel } from "./providers";

export interface AiExecutor {
  ocr(
    route: AiActionRouteInput,
    image: Uint8Array,
    mediaType: string,
  ): Promise<string>;
  tags(
    route: AiActionRouteInput,
    title: string,
    bodyMarkdown: string,
  ): Promise<readonly string[]>;
  translate(
    route: AiActionRouteInput,
    bodyMarkdown: string,
    targetLanguage: string,
  ): Promise<string>;
  title(route: AiActionRouteInput, bodyMarkdown: string): Promise<string>;
  agent(
    route: AiActionRouteInput,
    prompt: string,
    tools: ToolSet,
    maxSteps: number,
  ): Promise<{ readonly text: string; readonly toolCallCount: number }>;
}

const tagOutput = z.object({
  tags: z
    .array(z.string().min(1).max(80))
    .max(30)
    .describe("Concise lowercase ontology tags without duplicates"),
});

const titleOutput = z.object({
  title: z.string().min(1).max(120),
});

export class AiSdkExecutor implements AiExecutor {
  async ocr(
    route: AiActionRouteInput,
    image: Uint8Array,
    mediaType: string,
  ): Promise<string> {
    const result = await generateText({
      model: await resolveLanguageModel(route),
      system:
        "Transcribe the supplied image faithfully into Markdown. Preserve headings, lists, tables, and reading order. Do not explain the transcription.",
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: "Return the complete OCR transcription." },
            {
              type: "file",
              mediaType,
              data: { type: "data", data: image },
            },
          ],
        },
      ],
    });
    return result.text;
  }

  async tags(
    route: AiActionRouteInput,
    title: string,
    bodyMarkdown: string,
  ): Promise<readonly string[]> {
    const result = await generateText({
      model: await resolveLanguageModel(route),
      output: Output.object({ schema: tagOutput }),
      system:
        "Extract durable ontology tags for a note. Prefer specific entities, topics, people, years, events, and document kinds. Return only structured output.",
      prompt: `Title: ${title}\n\n${bodyMarkdown}`,
    });
    return result.output.tags;
  }

  async translate(
    route: AiActionRouteInput,
    bodyMarkdown: string,
    targetLanguage: string,
  ): Promise<string> {
    const result = await generateText({
      model: await resolveLanguageModel(route),
      system:
        "Translate Markdown faithfully. Preserve structure, links, code, identifiers, and front matter. Return only the translated Markdown.",
      prompt: `Target language: ${targetLanguage}\n\n${bodyMarkdown}`,
    });
    return result.text;
  }

  async title(
    route: AiActionRouteInput,
    bodyMarkdown: string,
  ): Promise<string> {
    const result = await generateText({
      model: await resolveLanguageModel(route),
      output: Output.object({ schema: titleOutput }),
      system: "Create a precise note title of at most 120 characters.",
      prompt: bodyMarkdown,
    });
    return result.output.title;
  }

  async agent(
    route: AiActionRouteInput,
    prompt: string,
    tools: ToolSet,
    maxSteps: number,
  ): Promise<{ readonly text: string; readonly toolCallCount: number }> {
    const result = await generateText({
      model: await resolveLanguageModel(route),
      tools,
      stopWhen: stepCountIs(maxSteps),
      system:
        "Use the supplied Kaiba GraphQL tools for all note reads and writes. Never invent note ids or claim a write that a tool did not confirm.",
      prompt,
    });
    return { text: result.text, toolCallCount: result.toolCalls.length };
  }
}
