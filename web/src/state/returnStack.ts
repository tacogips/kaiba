// In-app return stack (design-docs/specs/tag-detail-pane.md, T7): navigation
// initiated from the right pane pushes the current route hash; a visible Back
// control pops entries one by one. Pure list operations so the store stays
// testable without a DOM.

export const returnStackLimit = 50

export function pushReturn(stack: readonly string[], hash: string): string[] {
  // A no-move jump must not require two Back presses.
  if (stack[stack.length - 1] === hash) return [...stack]
  const next = [...stack, hash]
  return next.length > returnStackLimit ? next.slice(next.length - returnStackLimit) : next
}

export function popReturn(stack: readonly string[]): { stack: string[]; hash?: string } {
  if (stack.length === 0) return { stack: [] }
  const hash = stack[stack.length - 1]
  return hash === undefined
    ? { stack: [] }
    : { stack: stack.slice(0, -1), hash }
}
