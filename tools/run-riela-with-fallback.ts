import {
  fallbackWorkflow,
  primaryWorkflow,
  shouldUseCodexFallback,
  workflowRunArguments,
} from "./riela-fallback";

type CommandResult = {
  readonly exitCode: number;
  readonly output: string;
};

const passthrough = Bun.argv.slice(2);
const forceCodex = process.env["KAIBA_FORCE_CODEX_RIELA"] === "1";

const fallbackValidation = await run(
  ["workflow", "validate", fallbackWorkflow],
  false,
);
if (fallbackValidation.exitCode !== 0) {
  process.stderr.write(fallbackValidation.output);
  console.error(
    `[kaiba] Codex fallback workflow '${fallbackWorkflow}' is invalid or unavailable.`,
  );
  process.exit(fallbackValidation.exitCode);
}

const claudeAvailable = Bun.which("claude") !== null;
if (
  shouldUseCodexFallback({
    exitCode: 0,
    output: "",
    claudeExecutableAvailable: claudeAvailable,
    forceCodex,
  })
) {
  console.error(
    forceCodex
      ? `[kaiba] KAIBA_FORCE_CODEX_RIELA=1; using '${fallbackWorkflow}'.`
      : `[kaiba] Claude/Fable executable is unavailable; using '${fallbackWorkflow}'.`,
  );
  process.exit(
    (await run(workflowRunArguments(fallbackWorkflow, passthrough))).exitCode,
  );
}

const primaryValidation = await run(
  ["workflow", "validate", primaryWorkflow],
  false,
);
if (primaryValidation.exitCode !== 0) {
  process.stderr.write(primaryValidation.output);
  console.error(
    `[kaiba] Preferred workflow '${primaryWorkflow}' cannot be validated; using '${fallbackWorkflow}'.`,
  );
  process.exit(
    (await run(workflowRunArguments(fallbackWorkflow, passthrough))).exitCode,
  );
}

const primary = await run(workflowRunArguments(primaryWorkflow, passthrough));
if (primary.exitCode === 0) process.exit(0);

if (
  !shouldUseCodexFallback({
    exitCode: primary.exitCode,
    output: primary.output,
    claudeExecutableAvailable: true,
  })
) {
  console.error(
    `[kaiba] '${primaryWorkflow}' failed for a reason unrelated to Fable availability; the Codex fallback was not started.`,
  );
  process.exit(primary.exitCode);
}

console.error(
  `[kaiba] Fable became unavailable; continuing with Codex-only '${fallbackWorkflow}'.`,
);
process.exit(
  (await run(workflowRunArguments(fallbackWorkflow, passthrough))).exitCode,
);

async function run(
  arguments_: readonly string[],
  relayOutput = true,
): Promise<CommandResult> {
  const processHandle = Bun.spawn(["riela", ...arguments_], {
    cwd: process.cwd(),
    env: process.env,
    stdin: "inherit",
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    relay(processHandle.stdout, relayOutput ? process.stdout : undefined),
    relay(processHandle.stderr, relayOutput ? process.stderr : undefined),
    processHandle.exited,
  ]);
  return { exitCode, output: `${stdout}\n${stderr}` };
}

async function relay(
  stream: ReadableStream<Uint8Array>,
  destination: { write(chunk: Uint8Array): unknown } | undefined,
): Promise<string> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let output = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) return output + decoder.decode();
    destination?.write(value);
    output += decoder.decode(value, { stream: true });
  }
}
