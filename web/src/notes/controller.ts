import type { Notebook } from './types'

import type { NoteTag } from './types'

export type NotebookConstraint =
  | { kind: 'folder'; tagId: string; tagName: string; classId?: string | null }
  | { kind: 'tag'; tagId: string; tagName: string; classId: string | null }

export interface NotebookScope {
  constraints: NotebookConstraint[]
}

export interface NotebookScopeSnapshot {
  generation: number
  scope: NotebookScope
}

export class NotebookScopeController {
  private generation = 0
  private scope: NotebookScope = { constraints: [] }

  current(): NotebookScope {
    return cloneScope(this.scope)
  }

  select(constraint?: NotebookConstraint): NotebookScopeSnapshot {
    return this.replace(constraint ? [constraint] : [])
  }

  add(constraint: NotebookConstraint): NotebookScopeSnapshot {
    if (this.scope.constraints.some((current) => current.tagId === constraint.tagId)) {
      return this.snapshot()
    }
    return this.replace([...this.scope.constraints, constraint])
  }

  remove(tagId: string): NotebookScopeSnapshot {
    return this.replace(this.scope.constraints.filter((constraint) => constraint.tagId !== tagId))
  }

  clear(): NotebookScopeSnapshot {
    return this.replace([])
  }

  reconcile(tags: NoteTag[]): NotebookScopeSnapshot {
    const tagsById = new Map(tags.map((tag) => [tag.tagId, tag]))
    const seen = new Set<string>()
    const constraints: NotebookConstraint[] = []
    for (const constraint of this.scope.constraints) {
      const tag = tagsById.get(constraint.tagId)
      if (!tag || seen.has(tag.tagId)) continue
      seen.add(tag.tagId)
      constraints.push(constraintForTag(tag))
    }
    return sameConstraints(constraints, this.scope.constraints)
      ? this.snapshot()
      : this.replace(constraints)
  }

  snapshot(): NotebookScopeSnapshot {
    return { generation: this.generation, scope: cloneScope(this.scope) }
  }

  isCurrent(snapshot: NotebookScopeSnapshot): boolean {
    return snapshot.generation === this.generation
  }

  tagFilterIdGroups(snapshot = this.snapshot()): string[][] {
    return snapshot.scope.constraints.map((constraint) => [constraint.tagId])
  }

  private replace(constraints: NotebookConstraint[]): NotebookScopeSnapshot {
    if (sameConstraints(constraints, this.scope.constraints)) return this.snapshot()
    this.generation += 1
    this.scope = { constraints: constraints.map((constraint) => ({ ...constraint })) }
    return this.snapshot()
  }
}

export function constraintForTag(tag: NoteTag): NotebookConstraint {
  return tag.classId === 'folder'
    ? { kind: 'folder', tagId: tag.tagId, tagName: tag.name, classId: tag.classId }
    : { kind: 'tag', tagId: tag.tagId, tagName: tag.name, classId: tag.classId }
}

export function tagRemovalCanAffectConstraints(
  removedTag: Pick<NoteTag, 'tagId' | 'parentTagId'>,
  constraints: NotebookConstraint[],
  tags: NoteTag[],
): boolean {
  const activeIds = new Set(constraints.map((constraint) => constraint.tagId))
  const tagsById = new Map(tags.map((tag) => [tag.tagId, tag]))
  const visited = new Set<string>()
  let tagId: string | null | undefined = removedTag.tagId
  let parentTagId: string | null | undefined = removedTag.parentTagId
  while (tagId && !visited.has(tagId)) {
    if (activeIds.has(tagId)) return true
    visited.add(tagId)
    tagId = parentTagId
    parentTagId = tagId ? tagsById.get(tagId)?.parentTagId : undefined
  }
  return false
}

export function pruneNotebookActivatorEntries<T extends { isConnected: boolean }>(
  activators: Map<string, T>,
  acceptedNotebookIds: Iterable<string>,
): void {
  const acceptedIds = new Set(acceptedNotebookIds)
  for (const [notebookId, activator] of activators) {
    if (!acceptedIds.has(notebookId) || !activator.isConnected) activators.delete(notebookId)
  }
}

function cloneScope(scope: NotebookScope): NotebookScope {
  return { constraints: scope.constraints.map((constraint) => ({ ...constraint })) }
}

function sameConstraints(left: NotebookConstraint[], right: NotebookConstraint[]): boolean {
  return left.length === right.length && left.every((constraint, index) => {
    const current = right[index]
    return current?.kind === constraint.kind
      && current.tagId === constraint.tagId
      && current.tagName === constraint.tagName
      && (current.classId ?? null) === (constraint.classId ?? null)
  })
}

export interface ReadOnlyOperations {
  setReadOnly(notebookId: string, readOnly: boolean): Promise<Notebook>
}

export class NotebookReadOnlyController {
  private canonical = new Map<string, boolean>()
  private models = new Map<string, Notebook>()
  private modelVersions = new Map<string, number>()
  private desired = new Map<string, boolean>()
  private generations = new Map<string, number>()
  private stateVersions = new Map<string, number>()
  private running = new Map<string, Promise<void>>()

  constructor(
    private readonly operations: ReadOnlyOperations,
    private readonly onUpdate: (notebook: Notebook, error?: string) => void,
  ) {}

  snapshot(): ReadonlyMap<string, number> {
    return new Map(this.stateVersions)
  }

  adopt(notebook: Notebook, snapshot?: ReadonlyMap<string, number>): Notebook {
    const notebookId = notebook.notebookId
    const snapshotIsStale = snapshot
      && (snapshot.get(notebookId) ?? 0) !== this.stateVersion(notebookId)
    const readOnly = snapshotIsStale
      ? (this.canonical.get(notebookId) ?? notebook.readOnly)
      : notebook.readOnly
    const adopted = { ...notebook, readOnly }
    this.canonical.set(notebookId, readOnly)
    this.models.set(notebookId, adopted)
    this.bumpModelVersion(notebookId)
    return adopted
  }

  visible(notebook: Notebook): Notebook {
    const readOnly = this.canonical.get(notebook.notebookId) ?? notebook.readOnly
    return readOnly === notebook.readOnly ? notebook : { ...notebook, readOnly }
  }

  set(notebook: Notebook, readOnly: boolean): Promise<void> {
    const notebookId = notebook.notebookId
    if (notebook.readOnly === readOnly && !this.desired.has(notebookId)) return Promise.resolve()
    if (!this.models.has(notebookId)) this.adopt(notebook)
    this.desired.set(notebookId, readOnly)
    this.generations.set(notebookId, (this.generations.get(notebookId) ?? 0) + 1)
    this.bumpStateVersion(notebookId)
    const existing = this.running.get(notebookId)
    if (existing) return existing
    const operation = this.converge(notebookId).finally(() => this.running.delete(notebookId))
    this.running.set(notebookId, operation)
    return operation
  }

  private async converge(notebookId: string): Promise<void> {
    while (this.desired.has(notebookId)) {
      const target = this.desired.get(notebookId) as boolean
      const generation = this.generations.get(notebookId) ?? 0
      const modelVersion = this.modelVersion(notebookId)
      try {
        const updated = await this.operations.setReadOnly(notebookId, target)
        const reconciled = this.reconcileMutationResponse(notebookId, updated, modelVersion)
        this.canonical.set(notebookId, reconciled.readOnly)
        this.models.set(notebookId, reconciled)
        this.bumpModelVersion(notebookId)
        this.bumpStateVersion(notebookId)
        if (this.generations.get(notebookId) === generation && this.desired.get(notebookId) === target) {
          this.desired.delete(notebookId)
          this.onUpdate(reconciled)
        }
      } catch (error) {
        if (this.generations.get(notebookId) === generation && this.desired.get(notebookId) === target) {
          this.desired.delete(notebookId)
          this.bumpStateVersion(notebookId)
          const model = this.models.get(notebookId)
          if (model) this.onUpdate(model, errorMessage(error))
        }
      }
    }
  }

  private reconcileMutationResponse(
    notebookId: string,
    updated: Notebook,
    startedModelVersion: number,
  ): Notebook {
    const latest = this.models.get(notebookId)
    if (!latest || this.modelVersion(notebookId) === startedModelVersion) return updated
    return { ...latest, readOnly: updated.readOnly }
  }

  private modelVersion(notebookId: string): number {
    return this.modelVersions.get(notebookId) ?? 0
  }

  private bumpModelVersion(notebookId: string): void {
    this.modelVersions.set(notebookId, this.modelVersion(notebookId) + 1)
  }

  private stateVersion(notebookId: string): number {
    return this.stateVersions.get(notebookId) ?? 0
  }

  private bumpStateVersion(notebookId: string): void {
    this.stateVersions.set(notebookId, this.stateVersion(notebookId) + 1)
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
