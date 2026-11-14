# Implementation Plans

Implementation plans translate design documents into actionable work.

- Active plans live in `impl-plans/active/`.
- Completed plans move to `impl-plans/completed/`.
- Use `impl-plans/templates/plan-template.md` for new plans.
- Dispatch manifests (`*-dispatch.json`) are workflow runtime artifacts and stay
  in `impl-plans/active/` after their plans complete.

## Recently completed

- Tauri client connection settings (2026-10-25):
  `impl-plans/completed/tauri-client-connection.md`, plans P1-P5
  (`impl-plans/completed/tauri-client-connection-p1-endpoint-store.md`,
  `-p2-connection-probe.md`, `-p3-settings-ui.md`, `-p4-docs.md`,
  `-p5-bundle-build.md`). Design: `design-docs/specs/tauri-client-apps.md`.
