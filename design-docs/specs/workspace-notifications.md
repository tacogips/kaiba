# Workspace notifications and tab priority

The base stylesheet loads before the app and light theme. This prevents its
legacy dark-theme colors from overriding the light-surface text and buttons.
Errors use the shared dark-red foreground and pale-red surface tokens. Compiled
CSS verification measured error text at 6.41:1 contrast and informational toast
text at 5.90:1, above the 4.5:1 normal-text threshold.

Workspace error and informational notifications share a dismissible toast.
The close icon clears the notification immediately. Otherwise it expires after
eight seconds. Hovering or focusing the toast pauses the remaining time; leaving
it resumes that time. A replacement message gets a fresh eight seconds. Error
toasts preserve the Retry action where applicable and use an alert live region.
In-page errors remain in their original context.

Right-pane priority is AI, Tags, Analysis, Similar, Same topic, Related topics,
Backlinks. Existing tab keys and selected-tab preferences are preserved.

Validation, 2026-10-24: 195 Bun tests and 168 Vitest tests passed, including manual
close, expiration, hover/focus pause, replacement-message timing, and tab order.
`mise run web:check` and `mise run tauri:check` passed. The native browser showed
the requested missing-resource error, confirmed automatic and manual dismissal,
and verified the tab order. Verification used a separate tab and no test data
was written. Contrast evidence is in
`tmp/pdf-validation-20261024/error-contrast-check.json`.
