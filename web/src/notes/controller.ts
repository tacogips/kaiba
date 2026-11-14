import type { Notebook } from './types'

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
