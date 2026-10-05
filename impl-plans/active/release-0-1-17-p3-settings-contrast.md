# P3 Web Settings: legible primary and selected buttons

**Status**: Planned.
**planId**: P3-settings-contrast
**Wave**: 1
**dependsOn**: none. Web-only; no Swift.
**Design Reference**: `design-docs/specs/web-chatbook-ui.md` W16
**Index**: `impl-plans/active/release-0-1-17.md`

## Intent and context

In Settings (`#/config`, `web/src/views/ConfigView.tsx`), some buttons render near-white text (`#e5ffff`) on a near-white surface:

- the selected font-size preset: a `<button>` without `secondary` and with `aria-pressed="true"` (`ConfigView.tsx:34-39`);
- every primary (non-`secondary`) button in a `.config-section`, for example the personal-agent submit and Enable buttons at `web/src/components/UserAgentSettings.tsx:175-182`.

The cause is the stylesheet cascade (W16):

- `web/src/index.tsx` imports `styles.css` after `App.tsx` imports `light-theme.css`. The legacy dark rule `button:not(nav button)` at `web/src/styles.css:14` (`color: #e5ffff`, gradient `background` shorthand) therefore beats the equally specific `light-theme.css:31-34` rule.
- `web/src/workspace.css:10` (`.chatbook button:not(...)`) then sets `background-image: none`, which leaves a transparent fill.
- `secondary` buttons are fine because `light-theme.css:36-41` has `.chatbook button.secondary` rules.

`ConfigView` is mounted inside `.chatbook` (`web/src/views/ChatbookView.tsx:171,223`).

The fix appends two scoped light-theme rules, using existing tokens only:

- Primary: `.chatbook .config-section button:not(.secondary)` -> `color: var(--ink); border-color: var(--green-line); background: var(--green-primary);`. Its hover rule, `.chatbook .config-section button:not(.secondary):hover:not(:disabled)` -> `background: var(--green-hover);`.
- Selected: `.chatbook .config-section button[aria-pressed="true"]` -> `color: var(--green-ink); border-color: var(--green-focus); background: var(--green-selected);`. It must come after the primary rule, because both have specificity (0,3,1). This matches `light-theme.css:121` (`.study-note-button[aria-pressed="true"]`).

Token values (`light-theme.css:6-17`): `--ink #242529`, `--green-primary #eeeef1`, `--green-hover #e4e4e9`, `--green-ink #565a91`, `--green-selected #eaeaf0`. Expected contrast: about 13.2:1 (ink on primary), about 12.1:1 (ink on hover), about 5.37:1 (green-ink on selected), and about 5.08:1 (green-ink on hover). All are at least 4.5:1.

Theme scope: `light-theme.css` applies unconditionally on `:root`, and there is no dark-theme switch. The legacy dark base (`styles.css`, `workspace.css`) is left untouched, so "dark" behavior does not change (W16, accepted divergence DR-L2).

## Non-goals

- Do not edit `web/src/styles.css`, `web/src/workspace.css`, `web/src/index.tsx`, `web/src/App.tsx` or `web/index.html`, and do not change the import order.
- No new tokens or colors, and no changes outside `.config-section`.
- No TSX changes. Classes and `aria-pressed` are already correct.
- No `web/src-tauri` changes.

## writePaths

- `web/src/light-theme.css`
- `web/src/settingsButtonContrast.test.ts`
- `web/dist`
- `web/src-tauri/target`
- `impl-plans/active/release-0-1-17-p3-settings-contrast.md`
- `tmp/release-0-1-17/P3`

## sharedPaths (read-only)

- `web/src/views/ConfigView.tsx`
- `web/src/components/UserAgentSettings.tsx`
- `web/src/notes/engineBoundary.test.ts`
- `web/package.json`
- `web/vitest.config.ts`

## sharedPathNotes

- `web/src/light-theme.css`: append the three rules, in this order, at the end of the file under a one-line comment such as `/* Settings primary/selected buttons (W16): override the legacy dark button cascade. */`. Change nothing else.
- `web/src/settingsButtonContrast.test.ts`: new bun test, picked up by `bun test src` (`*.test.ts`). Vitest only includes `src/**/*.integration.tsx`.
- `web/src/notes/engineBoundary.test.ts`: read-only. Imitate its `node:fs` / `node:path` / `import.meta.dir` / `bun:test` pattern (lines 1-5).
- `web/dist`: generated `vite build` output from `mise run web:check` only (gitignored).
- `web/src-tauri/target`: generated cargo output from `mise run tauri:check` only (gitignored); never edited by hand.
- `tmp/release-0-1-17/P3`: evidence logs, `hashes.txt` and `intent.md` only.

## artifactRoots

- `web/dist`
- `web/src-tauri/target`
- `tmp/release-0-1-17/P3`

## File-level changes

1. `light-theme.css`: the three rules above, appended.
2. `settingsButtonContrast.test.ts` (new):
   - Read `light-theme.css` with `readFileSync(resolve(import.meta.dir, 'light-theme.css'), 'utf8')`.
   - Parse the first `:root { ... }` block into a token map with a regex over `--name: #rrggbb;`.
   - Implement the WCAG 2.x relative luminance and contrast ratio as small local helpers (sRGB linearization with the 0.03928 threshold).
   - To check rule bodies, find the selector text, then take the declaration block up to the next `}` and normalize whitespace.

## Pitfalls

- Use the `background:` shorthand in the primary and selected rules, not `background-color` alone. The legacy `styles.css:14` rule sets a gradient through the shorthand. A more specific shorthand resets both the image and the color, so the result does not depend on `workspace.css:10`.
- Keep the selected rule after the primary rule, or the selected preset will look identical to an unselected primary.
- Do not use `!important`.
- Do not scope to `.config-presets` only: the primary submit buttons sit in `.config-section` forms.
- The test must fail if someone deletes a rule or swaps a token, so assert the exact `var(--token)` names, not just the selectors.

## Tests (input or situation -> expected outcome)

`web/src/settingsButtonContrast.test.ts` (bun):

- `light-theme.css` text -> contains the selector `.chatbook .config-section button:not(.secondary)` with a body containing `color: var(--ink)` and `background: var(--green-primary)`.
- It contains `.chatbook .config-section button[aria-pressed="true"]`, with a body containing `color: var(--green-ink)` and `background: var(--green-selected)`. That selector's index is greater than the primary rule's index.
- It contains the hover rule `.chatbook .config-section button:not(.secondary):hover:not(:disabled)` with `var(--green-hover)`.
- Token contrast, computed from the parsed `:root` -> `contrast(--ink, --green-primary) >= 4.5`, `contrast(--ink, --green-hover) >= 4.5`, `contrast(--green-ink, --green-selected) >= 4.5`, `contrast(--green-ink, --green-hover) >= 4.5`.
- Sanity -> `contrast('#ffffff', '#000000')` is about 21 (`toBeCloseTo(21, 0)`), and the token map has at least those five tokens, so a broken parser fails loudly.

Manual browser check (not a gate; record it as environment-blocked if no browser is available, per `web-chatbook-ui.md` Verification): with `kaiba serve --web-root web/dist`, at `#/config` the selected preset and the Save/Enable buttons are legible at rest, on hover and when focused.

## Verification

```bash
mkdir -p tmp/release-0-1-17/P3
bash -c 'cd web && mise exec -- bun test src 2>&1 | tee ../tmp/release-0-1-17/P3/bun-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/release-0-1-17/P3/vitest.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run web:check 2>&1 | tee tmp/release-0-1-17/P3/web-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run tauri:check 2>&1 | tee tmp/release-0-1-17/P3/tauri-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'git diff --name-only -- web/src/styles.css web/src/workspace.css web/src/index.tsx web/src/App.tsx web/index.html | tee tmp/release-0-1-17/P3/guard-protected.log; test ! -s tmp/release-0-1-17/P3/guard-protected.log'
```

Expected evidence:

- `bun test src`: exit 0, `N pass` and `0 fail`, N > 0. Record N; it includes the new file.
- `vitest run`: exit 0, `Tests M passed`, M > 0. Record M separately.
- `web:check` exit 0. This is not a behavioral record, and it writes `web/dist`.
- `tauri:check` exit 0 on macOS. If unavailable, record `blocked: <exact error>`, never passed. P4 reruns it.
- The protected guard log is empty.

## Done criteria

- [ ] The three rules are appended in order, using existing tokens only, with no `!important`.
- [ ] The new bun test passes, and fails if a rule or token is removed (checked by reasoning about the assertions).
- [ ] bun and vitest counts are recorded separately with exit 0; `web:check` and `tauri:check` exit 0.
- [ ] Protected web files are unchanged.
- [ ] The Progress Log records commands, exit codes, counts and log paths.

## Progress Log

- 2026-10-05: Plan created.
