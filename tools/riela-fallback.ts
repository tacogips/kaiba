export const primaryWorkflow = "fable-and-improve-codex";
export const fallbackWorkflow = "codex-goal";

const fableActor = String.raw`(?:claude(?:[ -]code)?(?:-agent)?|fable)`;
const unavailableReason = String.raw`(?:unavailable|not available|not found|enoent|failed to spawn|authentication|unauthorized|forbidden|rate limit|quota|capacity|overloaded|backend invocation failed|model[^\n]{0,40}(?:missing|not found|unavailable))`;

const fableUnavailablePatterns = [
  new RegExp(`${fableActor}[^\n]{0,200}${unavailableReason}`, "i"),
  new RegExp(`${unavailableReason}[^\n]{0,200}${fableActor}`, "i"),
  /fable-(?:analysis|design|impl-plan|goal-review)[^\n]{0,200}(?:backend|invocation|spawn|authentication)[^\n]{0,100}fail/i,
];

export type FallbackDecisionInput = {
  readonly exitCode: number;
  readonly output: string;
  readonly claudeExecutableAvailable: boolean;
  readonly forceCodex?: boolean | undefined;
};

export function shouldUseCodexFallback(input: FallbackDecisionInput): boolean {
  if (input.forceCodex) return true;
  if (!input.claudeExecutableAvailable) return true;
  if (input.exitCode === 0) return false;
  return fableUnavailablePatterns.some((pattern) => pattern.test(input.output));
}

export function workflowRunArguments(
  workflow: string,
  passthrough: readonly string[],
): readonly string[] {
  return ["workflow", "run", workflow, ...passthrough];
}
