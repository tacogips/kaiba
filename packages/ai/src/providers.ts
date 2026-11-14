import type { LanguageModel } from "ai";
import type { AiActionRouteInput } from "./config";

export async function resolveLanguageModel(
  route: AiActionRouteInput,
): Promise<LanguageModel> {
  switch (route.vendor) {
    case "openai": {
      const { createOpenAI } = await import("@ai-sdk/openai");
      return createOpenAI({ apiKey: route.apiKey })(route.model);
    }
    case "anthropic": {
      const { createAnthropic } = await import("@ai-sdk/anthropic");
      return createAnthropic({ apiKey: route.apiKey })(route.model);
    }
    case "google": {
      const { createGoogleGenerativeAI } = await import("@ai-sdk/google");
      return createGoogleGenerativeAI({ apiKey: route.apiKey })(route.model);
    }
    case "openai-compatible": {
      const { createOpenAICompatible } = await import(
        "@ai-sdk/openai-compatible"
      );
      return createOpenAICompatible({
        name: "kaiba-user-provider",
        apiKey: route.apiKey,
        baseURL: requiredBaseURL(route),
      })(route.model);
    }
  }
}

function requiredBaseURL(route: AiActionRouteInput): string {
  if (!route.baseURL) {
    throw new Error("OpenAI-compatible provider is missing baseURL");
  }
  return route.baseURL;
}
