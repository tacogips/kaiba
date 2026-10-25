# P4: README user docs and spec typo

planId: `tauri-client-connection-p4-docs`. Wave 1, with no dependencies.
Status: accepted in session opus-luna-design-and-implement-review-loop-session-481
(test-integrity and adversarial review). Its changes are in the working tree.
Do not redispatch; the dispatch manifest lists it under `acceptedDependencies`.
Completed: P5's combined-tree gates passed in session 483, and the plan was
moved to `impl-plans/completed/` at Step 8 on 2026-10-25.
Index and shared rules: `impl-plans/completed/tauri-client-connection.md`.
Design: `design-docs/specs/tauri-client-apps.md`, "Connection settings". The
accepted design text is the source of truth. Describe it; do not extend it.

## Intent and context

`README.md` section "## macOS and iPhone clients" (around lines 476-523) is
what a user actually reads before running `mise run tauri:build`. It
describes the Local/Remote choice but not the new controls. Step 3 also
found a stray pre-existing word `An` at the end of a line in the spec, in
the paragraph that ends "...no confirmation prompt is needed because
nothing was lost." (around line 268), just before "Clearing is per
origin...".

## writePaths

- `README.md`
- `design-docs/specs/tauri-client-apps.md`
- `tmp/tauri-client-connection/P4`

## Exact changes

1. `README.md`: in the paragraph that begins "In Settings > Server
   connection, choose **Local — this Mac** or **Remote server**.", or
   directly after it, add one short paragraph (at most 8 lines) that states
   the following facts and nothing beyond the design:
   - Settings shows the active connection (Local, or the remote host).
   - **Test connection** checks an unsaved remote URL. It can report
     connected, sign-in required, not a kaiba server, unreachable, or a
     server error, and it sends no API key.
   - Saving a remote URL adds it to **Recent servers** (the last 5, stored
     on this device). Picking one fills the URL field.
   - A plain `http` URL to a non-loopback host shows a warning that the key
     travels unencrypted. It is not blocked.
   - The same form appears on the sign-in screen, and Settings stays
     reachable when the server cannot be reached.
2. `design-docs/specs/tauri-client-apps.md`: delete only the dangling word
   `An` at the end of "...because nothing was lost. An", so the sentence
   ends at "lost.". Change nothing else in the spec.

## Pitfalls

- Do not touch other README sections, including the naming-collision
  paragraph, which must stay.
- Do not invent behavior: no first-run chooser, no deletion of recent
  entries, no credential pruning.
- No emojis. Use the em dash only where the existing UI text already uses it
  (`Local — this Mac`).
- Use the same edit protocol: fresh read, pre/post hashes. `README.md` is
  owned by this plan alone.

## Verification (tee'd into `tmp/tauri-client-connection/P4/`)

- `git diff --stat -- README.md design-docs/specs/tauri-client-apps.md`:
  shows only these two files, with README gaining at most about 10 lines.
- `grep -n "nothing was lost. An" design-docs/specs/tauri-client-apps.md`
  matches nothing (exit 1).
- `grep -n "Test connection" README.md` includes a match inside the
  "macOS and iPhone clients" section.
- `grep -nP "[\x{1F300}-\x{1FAFF}]" README.md` matches nothing.

## Done criteria

- All four checks above hold.
- `tmp/tauri-client-connection/P4/progress.md` ends with `status: done`.
