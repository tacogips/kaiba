import type { KanbanStatus, KanbanStatusSet } from './types'

// Column placement for the notebook board. The mapping is deterministic and
// client-side so a notebook whose progress value is unknown to the active status
// set still lands in a column instead of disappearing.

export const defaultStatusSet: KanbanStatusSet = {
  setId: 'kanban-default',
  name: 'default',
  isSystem: true,
  statuses: [
    { statusId: 'kanban-default-none', name: 'none', category: 'none', position: 0 },
    { statusId: 'kanban-default-pending', name: 'pending', category: 'pending', position: 1 },
    { statusId: 'kanban-default-progress', name: 'progress', category: 'progress', position: 2 },
    { statusId: 'kanban-default-review', name: 'review', category: 'review', position: 3 },
    { statusId: 'kanban-default-done', name: 'done', category: 'done', position: 4 },
  ],
}

const defaultStatusLabels: Record<string, string> = {
  none: 'No status',
  pending: 'Pending',
  progress: 'In progress',
  review: 'In review',
  done: 'Done',
}

export function statusLabel(status: Pick<KanbanStatus, 'name'>): string {
  return defaultStatusLabels[status.name] ?? status.name
}

/** Direct name match, else the first column whose category matches the
 * (default-name) category, else the first none-category column, else the first
 * column. Cards are never dropped. */
export function boardColumnIndex(progress: string, statuses: KanbanStatus[]): number {
  const direct = statuses.findIndex((status) => status.name === progress)
  if (direct >= 0) return direct
  const category = defaultStatusSet.statuses.find((status) => status.name === progress)?.category ?? 'none'
  const byCategory = statuses.findIndex((status) => status.category === category)
  if (byCategory >= 0) return byCategory
  const noneColumn = statuses.findIndex((status) => status.category === 'none')
  return noneColumn >= 0 ? noneColumn : 0
}

export function statusCategoryFor(progress: string, statuses: KanbanStatus[]): string {
  return statuses[boardColumnIndex(progress, statuses)]?.category ?? 'none'
}

export function progressLabelFor(progress: string, statuses: KanbanStatus[]): string {
  const direct = statuses.find((status) => status.name === progress)
  if (direct) return statusLabel(direct)
  return defaultStatusLabels[progress] ?? progress
}
