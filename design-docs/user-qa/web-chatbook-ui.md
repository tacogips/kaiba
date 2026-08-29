# Web Chatbook UI Decisions

Design reference: `design-docs/specs/web-chatbook-ui.md`

Recorded 2026-08-29 while closing verification for the right-pane agent composer plan.

## Question 1

The composer's responsive-breakpoint, light/dark state-distinguishability, and
keyboard-only checks currently live outside the mechanical gate: they need a
browser runtime, so on machines without one they can only be recorded as
environment-blocked. Should these stay permanently manual, or should the project
add an automated browser check (for example a headless Playwright run) to
`web/package.json`'s `check` script so the gate covers them?

## Status

Pending
