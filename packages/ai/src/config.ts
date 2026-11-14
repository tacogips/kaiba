export const aiActions = [
  "ocr",
  "tagging",
  "translation",
  "agent",
  "agentSearch",
  "title",
] as const;

export type AiAction = (typeof aiActions)[number];
export type AiVendor = "openai" | "anthropic" | "google" | "openai-compatible";

export type AiActionRouteInput = {
  readonly vendor: AiVendor;
  readonly model: string;
  readonly apiKey: string;
  readonly baseURL?: string | undefined;
};

export type RedactedAiActionRoute = {
  readonly vendor: AiVendor;
  readonly model: string;
  readonly baseURL?: string | undefined;
  readonly keyPresent: true;
};

export class AiConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AiConfigurationError";
  }
}

export class AiActionRouter {
  readonly #routes = new Map<AiAction, AiActionRouteInput>();

  constructor(routes: Partial<Record<AiAction, AiActionRouteInput>>) {
    for (const action of aiActions) {
      const route = routes[action];
      if (route) this.#routes.set(action, validateRoute(action, route));
    }
  }

  resolve(action: AiAction): AiActionRouteInput {
    const route = this.#routes.get(action);
    if (!route) {
      throw new AiConfigurationError(`AI action '${action}' is not configured`);
    }
    return route;
  }

  redacted(): Partial<Record<AiAction, RedactedAiActionRoute>> {
    const result: Partial<Record<AiAction, RedactedAiActionRoute>> = {};
    for (const [action, route] of this.#routes) {
      result[action] = {
        vendor: route.vendor,
        model: route.model,
        ...(route.baseURL ? { baseURL: route.baseURL } : {}),
        keyPresent: true,
      };
    }
    return result;
  }
}

function validateRoute(
  action: AiAction,
  route: AiActionRouteInput,
): AiActionRouteInput {
  const apiKey = route.apiKey.trim();
  const model = route.model.trim();
  if (!apiKey) {
    throw new AiConfigurationError(
      `AI action '${action}' requires a user API key`,
    );
  }
  if (!model) {
    throw new AiConfigurationError(`AI action '${action}' requires a model`);
  }
  if (route.vendor === "openai-compatible") {
    if (!route.baseURL) {
      throw new AiConfigurationError(
        `AI action '${action}' requires an OpenAI-compatible baseURL`,
      );
    }
    const url = new URL(route.baseURL);
    if (url.protocol !== "https:" && url.hostname !== "localhost") {
      throw new AiConfigurationError(
        `AI action '${action}' baseURL must use HTTPS`,
      );
    }
  }
  return {
    vendor: route.vendor,
    model,
    apiKey,
    ...(route.baseURL ? { baseURL: route.baseURL.replace(/\/$/, "") } : {}),
  };
}
