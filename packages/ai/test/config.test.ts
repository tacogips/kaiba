import { describe, expect, test } from "vitest";
import { AiActionRouter, AiConfigurationError } from "../src/config";

describe("AiActionRouter", () => {
  test("selects vendors independently per action and redacts keys", () => {
    const router = new AiActionRouter({
      ocr: { vendor: "google", model: "gemini-image", apiKey: "google-secret" },
      tagging: {
        vendor: "anthropic",
        model: "claude-tags",
        apiKey: "anthropic-secret",
      },
    });

    expect(router.resolve("ocr").vendor).toBe("google");
    expect(router.resolve("tagging").vendor).toBe("anthropic");
    expect(JSON.stringify(router.redacted())).not.toContain("secret");
    expect(router.redacted()).toMatchObject({
      ocr: { vendor: "google", keyPresent: true },
      tagging: { vendor: "anthropic", keyPresent: true },
    });
  });

  test("requires a user key for every configured action", () => {
    expect(
      () =>
        new AiActionRouter({
          ocr: { vendor: "openai", model: "vision", apiKey: "" },
        }),
    ).toThrow(AiConfigurationError);
  });

  test("fails closed when an action has no route", () => {
    const router = new AiActionRouter({});
    expect(() => router.resolve("translation")).toThrow("not configured");
  });
});
