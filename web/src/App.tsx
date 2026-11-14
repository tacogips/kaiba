import {
  KaibaAi,
  aiActions,
  type AiAction,
  type AiActionRouteInput,
  type AiVendor,
  type KaibaNote,
} from "@kaiba/ai";
import { For, Show, createMemo, createSignal, onMount } from "solid-js";
import { createNote, listNotes, type ApiOptions } from "./api";

type RouteDraft = {
  vendor: AiVendor;
  model: string;
  apiKey: string;
  baseURL: string;
};

const editableActions: readonly AiAction[] = [
  "ocr",
  "tagging",
  "translation",
  "agent",
  "agentSearch",
  "title",
];

const emptyRoute = (): RouteDraft => ({
  vendor: "openai",
  model: "",
  apiKey: "",
  baseURL: "",
});

export function App() {
  const [endpoint, setEndpoint] = createSignal(
    import.meta.env.VITE_GRAPHQL_URL ?? `${location.origin}/graphql`,
  );
  const [token, setToken] = createSignal("");
  const [notes, setNotes] = createSignal<readonly KaibaNote[]>([]);
  const [selectedId, setSelectedId] = createSignal<string>();
  const [newBody, setNewBody] = createSignal("# New note\n");
  const [targetLanguage, setTargetLanguage] = createSignal("Japanese");
  const [agentPrompt, setAgentPrompt] = createSignal("");
  const [status, setStatus] = createSignal("Ready");
  const [routes, setRoutes] = createSignal<Record<AiAction, RouteDraft>>(
    Object.fromEntries(
      aiActions.map((action) => [action, emptyRoute()]),
    ) as Record<AiAction, RouteDraft>,
  );

  const apiOptions = (): ApiOptions => ({
    endpoint: endpoint(),
    ...(token() ? { token: token() } : {}),
  });
  const selected = createMemo(() =>
    notes().find((note) => note.id === selectedId()),
  );

  onMount(() => void refresh());

  async function refresh() {
    await run("Loading notes", async () => {
      const loaded = await listNotes(apiOptions());
      setNotes(loaded);
      if (!selectedId() && loaded[0]) setSelectedId(loaded[0].id);
    });
  }

  async function addNote() {
    await run("Creating note", async () => {
      const note = await createNote(apiOptions(), newBody());
      setNotes((current) => [note, ...current]);
      setSelectedId(note.id);
    });
  }

  async function tagSelected() {
    const note = requiredSelected();
    await run("Tagging note", async () => {
      const result = await runtime().tagNote({ noteId: note.id });
      replaceNote(result.note);
    });
  }

  async function translateSelected() {
    const note = requiredSelected();
    await run("Translating note", async () => {
      const result = await runtime().translateNote({
        noteId: note.id,
        targetLanguage: targetLanguage(),
        writeBack: true,
      });
      replaceNote(result.note);
    });
  }

  async function titleSelected() {
    const note = requiredSelected();
    await run("Generating title", async () => {
      const result = await runtime().titleNote({
        noteId: note.id,
        writeBack: true,
      });
      replaceNote(result.note);
    });
  }

  async function runAgentSearch() {
    await run("Running read-only agent search", async () => {
      const result = await runtime().agentSearch(agentPrompt());
      setStatus(result.text || `Completed ${result.toolCallCount} tool calls`);
    });
  }

  async function runOcr(file?: File) {
    if (!file) return;
    await run("Running OCR", async () => {
      const markdown = await runtime().ocr(
        new Uint8Array(await file.arrayBuffer()),
        file.type || "image/png",
      );
      setNewBody(markdown);
      setStatus("OCR is ready in the new-note editor");
    });
  }

  function runtime(): KaibaAi {
    const configured: Partial<Record<AiAction, AiActionRouteInput>> = {};
    for (const action of editableActions) {
      const draft = routes()[action];
      if (!draft.apiKey || !draft.model) continue;
      configured[action] = {
        vendor: draft.vendor,
        model: draft.model,
        apiKey: draft.apiKey,
        ...(draft.baseURL ? { baseURL: draft.baseURL } : {}),
      };
    }
    return new KaibaAi({ kaiba: apiOptions(), routes: configured });
  }

  function updateRoute(action: AiAction, update: Partial<RouteDraft>) {
    setRoutes((current) => ({
      ...current,
      [action]: { ...current[action], ...update },
    }));
  }

  function requiredSelected(): KaibaNote {
    const note = selected();
    if (!note) throw new Error("Select a note first");
    return note;
  }

  function replaceNote(note: KaibaNote) {
    setNotes((current) =>
      current.map((item) => (item.id === note.id ? note : item)),
    );
  }

  async function run(label: string, operation: () => Promise<void>) {
    setStatus(`${label}…`);
    try {
      await operation();
      if (status().endsWith("…")) setStatus(`${label} complete`);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Operation failed");
    }
  }

  return (
    <main>
      <header>
        <div>
          <p class="eyebrow">Cloudflare Workers / BYOK</p>
          <h1>Kaiba</h1>
        </div>
        <p class="status">{status()}</p>
      </header>

      <section class="connection card">
        <label>
          GraphQL endpoint
          <input
            value={endpoint()}
            onInput={(event) => setEndpoint(event.currentTarget.value)}
          />
        </label>
        <label>
          Kaiba API token
          <input
            type="password"
            value={token()}
            onInput={(event) => setToken(event.currentTarget.value)}
          />
        </label>
        <button type="button" onClick={() => void refresh()}>
          Connect
        </button>
      </section>

      <div class="workspace">
        <aside class="card notes">
          <h2>Notes</h2>
          <For each={notes()} fallback={<p>No notes yet.</p>}>
            {(note) => (
              <button
                type="button"
                classList={{ selected: note.id === selectedId() }}
                onClick={() => setSelectedId(note.id)}
              >
                <strong>{note.title}</strong>
                <small>
                  {note.tags.map((tag) => tag.name).join(" · ") || "untagged"}
                </small>
              </button>
            )}
          </For>
        </aside>

        <section class="card editor">
          <Show when={selected()} fallback={<p>Select a note.</p>}>
            {(note) => (
              <>
                <p class="eyebrow">{note().id}</p>
                <h2>{note().title}</h2>
                <pre>{note().bodyMarkdown}</pre>
                <div class="actions">
                  <button type="button" onClick={() => void tagSelected()}>
                    AI tag
                  </button>
                  <button type="button" onClick={() => void titleSelected()}>
                    AI title
                  </button>
                  <input
                    value={targetLanguage()}
                    onInput={(event) =>
                      setTargetLanguage(event.currentTarget.value)
                    }
                  />
                  <button
                    type="button"
                    onClick={() => void translateSelected()}
                  >
                    AI translate
                  </button>
                </div>
              </>
            )}
          </Show>
          <h2>New note / OCR result</h2>
          <textarea
            value={newBody()}
            onInput={(event) => setNewBody(event.currentTarget.value)}
          />
          <div class="actions">
            <input
              type="file"
              accept="image/*"
              onChange={(event) => void runOcr(event.currentTarget.files?.[0])}
            />
            <button type="button" onClick={() => void addNote()}>
              Create note
            </button>
          </div>
        </section>
      </div>

      <section class="card">
        <p class="eyebrow">Session-only credentials</p>
        <h2>AI routing by action</h2>
        <p>
          Keys stay in this page's memory and are sent only to the selected AI
          vendor, never to Kaiba GraphQL.
        </p>
        <div class="routes">
          <For each={editableActions}>
            {(action) => (
              <fieldset>
                <legend>{action}</legend>
                <select
                  value={routes()[action].vendor}
                  onInput={(event) =>
                    updateRoute(action, {
                      vendor: event.currentTarget.value as AiVendor,
                    })
                  }
                >
                  <option value="openai">OpenAI</option>
                  <option value="anthropic">Anthropic</option>
                  <option value="google">Google</option>
                  <option value="openai-compatible">OpenAI-compatible</option>
                </select>
                <input
                  placeholder="Model"
                  value={routes()[action].model}
                  onInput={(event) =>
                    updateRoute(action, { model: event.currentTarget.value })
                  }
                />
                <input
                  type="password"
                  placeholder="User API key"
                  value={routes()[action].apiKey}
                  onInput={(event) =>
                    updateRoute(action, { apiKey: event.currentTarget.value })
                  }
                />
                <Show when={routes()[action].vendor === "openai-compatible"}>
                  <input
                    placeholder="HTTPS base URL"
                    value={routes()[action].baseURL}
                    onInput={(event) =>
                      updateRoute(action, {
                        baseURL: event.currentTarget.value,
                      })
                    }
                  />
                </Show>
              </fieldset>
            )}
          </For>
        </div>
        <div class="agent-search">
          <input
            placeholder="Ask a read-only question about Kaiba"
            value={agentPrompt()}
            onInput={(event) => setAgentPrompt(event.currentTarget.value)}
          />
          <button type="button" onClick={() => void runAgentSearch()}>
            Agent search
          </button>
        </div>
      </section>
    </main>
  );
}
