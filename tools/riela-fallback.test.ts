import { describe, expect, test } from "vitest";
import {
  fallbackWorkflow,
  shouldUseCodexFallback,
  workflowRunArguments,
} from "./riela-fallback";

describe("Riela Fable fallback", () => {
  test("uses Codex when Claude is not installed", () => {
    expect(
      shouldUseCodexFallback({
        exitCode: 0,
        output: "",
        claudeExecutableAvailable: false,
      }),
    ).toBe(true);
  });

  test("uses Codex for Fable backend availability failures", () => {
    expect(
      shouldUseCodexFallback({
        exitCode: 1,
        output:
          "step fable-analysis: claude-code-agent backend invocation failed: model unavailable",
        claudeExecutableAvailable: true,
      }),
    ).toBe(true);
  });

  test("does not hide unrelated workflow failures", () => {
    expect(
      shouldUseCodexFallback({
        exitCode: 1,
        output: "verification failed: unit test assertion mismatch",
        claudeExecutableAvailable: true,
      }),
    ).toBe(false);
  });

  test("preserves runtime arguments for the Codex workflow", () => {
    expect(
      workflowRunArguments(fallbackWorkflow, [
        "--variables-file",
        "request.json",
        "--output",
        "jsonl",
      ]),
    ).toEqual([
      "workflow",
      "run",
      "codex-goal",
      "--variables-file",
      "request.json",
      "--output",
      "jsonl",
    ]);
  });
});
