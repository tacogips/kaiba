import type { NoteTag, NoteTagAssignment, NoteTagClass } from './types'

export interface TagTreeNode {
  tag: NoteTag
  children: TagTreeNode[]
}

export type FolderNode = TagTreeNode

export interface TagCatalogGroup {
  key: string
  classId: string | null
  label: string
  tags: NoteTag[]
  tree: TagTreeNode[]
  knownClass: boolean
}

export interface TagAssignmentGroup {
  key: string
  classId: string | null
  label: string
  assignments: NoteTagAssignment[]
}

export interface TagBreadcrumbSegment {
  label: string
  tag?: NoteTag
  incomplete: boolean
}

export function folderTags(tags: NoteTag[]): NoteTag[] {
  return tags.filter((tag) => tag.classId === 'folder')
}

export function buildTagTree(tags: NoteTag[], classId: string, locale?: string): TagTreeNode[] {
  const classTags = tags.filter((tag) => tag.classId === classId)
  const byId = new Map(classTags.map((tag) => [tag.tagId, tag]))
  const children = new Map<string, NoteTag[]>()
  const roots: NoteTag[] = []
  for (const tag of classTags) {
    const parentId = tag.parentTagId
    if (!parentId || !byId.has(parentId) || parentId === tag.tagId) {
      roots.push(tag)
    } else {
      children.set(parentId, [...(children.get(parentId) ?? []), tag])
    }
  }
  const sort = tagSorter(locale)
  const visited = new Set<string>()
  const makeNode = (tag: NoteTag, ancestry: Set<string>): TagTreeNode => {
    if (ancestry.has(tag.tagId)) return { tag, children: [] }
    const nextAncestry = new Set(ancestry).add(tag.tagId)
    visited.add(tag.tagId)
    return {
      tag,
      children: sort(children.get(tag.tagId) ?? []).map((child) => makeNode(child, nextAncestry)),
    }
  }
  const nodes = sort(roots).map((tag) => makeNode(tag, new Set()))
  for (const orphan of sort(classTags.filter((tag) => !visited.has(tag.tagId)))) {
    nodes.push(makeNode(orphan, new Set()))
  }
  return nodes
}

export function buildFolderTree(tags: NoteTag[], locale?: string): TagTreeNode[] {
  return buildTagTree(tags, 'folder', locale)
}

export function tagBreadcrumb(
  tags: NoteTag[],
  selectedId: string | undefined,
  classId: string,
): NoteTag[] {
  if (!selectedId) return []
  const byId = new Map(tags.filter((tag) => tag.classId === classId).map((tag) => [tag.tagId, tag]))
  const path: NoteTag[] = []
  const visited = new Set<string>()
  let current = byId.get(selectedId)
  while (current && !visited.has(current.tagId)) {
    visited.add(current.tagId)
    path.unshift(current)
    current = current.parentTagId ? byId.get(current.parentTagId) : undefined
  }
  return path
}

export function folderBreadcrumb(tags: NoteTag[], selectedId?: string): NoteTag[] {
  return tagBreadcrumb(tags, selectedId, 'folder')
}

export function qualifiedTagBreadcrumb(
  tags: NoteTag[],
  selectedId: string | undefined,
  depthLimit = 64,
): TagBreadcrumbSegment[] {
  if (!selectedId) return []
  const byId = new Map(tags.map((tag) => [tag.tagId, tag]))
  const leaf = byId.get(selectedId)
  if (!leaf) return [{ label: `[missing: ${selectedId}]`, incomplete: true }]
  const segments: TagBreadcrumbSegment[] = []
  const visited = new Set<string>()
  let current: NoteTag | undefined = leaf
  for (let depth = 0; current && depth < depthLimit; depth += 1) {
    if (visited.has(current.tagId)) {
      segments.unshift({ label: `[cycle: ${current.tagId}]`, incomplete: true })
      return segments
    }
    visited.add(current.tagId)
    segments.unshift({ label: current.name, tag: current, incomplete: false })
    if (!current.parentTagId) return segments
    const parent = byId.get(current.parentTagId)
    if (!parent) {
      segments.unshift({ label: `[missing: ${current.parentTagId}]`, incomplete: true })
      return segments
    }
    current = parent
  }
  segments.unshift({ label: `[depth: ${selectedId}]`, incomplete: true })
  return segments
}

export function navigationTagGroups(
  tags: NoteTag[],
  classes: NoteTagClass[],
  locale?: string,
): TagCatalogGroup[] {
  return catalogGroups(tags, classes, false, locale)
    .filter((group) => group.tags.length > 0)
}

export function assignableTagGroups(
  tags: NoteTag[],
  classes: NoteTagClass[],
  locale?: string,
): TagCatalogGroup[] {
  return catalogGroups(tags, classes, true, locale)
}

export function groupTagAssignments(
  assignments: NoteTagAssignment[],
  classes: NoteTagClass[],
  locale?: string,
): TagAssignmentGroup[] {
  const collator = new Intl.Collator(locale, { sensitivity: 'base' })
  const classesById = new Map(classes.map((tagClass) => [tagClass.classId, tagClass]))
  const byClass = new Map<string | null, NoteTagAssignment[]>()
  for (const assignment of assignments) {
    const classId = assignment.tag.classId
    byClass.set(classId, [...(byClass.get(classId) ?? []), assignment])
  }
  const sortAssignments = (values: NoteTagAssignment[]) => [...values].sort((left, right) =>
    collator.compare(left.tag.name, right.tag.name) || left.tag.tagId.localeCompare(right.tag.tagId))
  const folder = byClass.get('folder')
  const named = [...byClass.entries()]
    .filter(([classId]) => classId !== null && classId !== 'folder')
    .map(([classId, values]) => {
      const resolvedClassId = classId as string
      return {
        key: groupKey(resolvedClassId),
        classId: resolvedClassId,
        label: classesById.get(resolvedClassId)?.label ?? unknownClassLabel(resolvedClassId),
        assignments: sortAssignments(values),
      }
    })
    .sort((left, right) =>
      collator.compare(left.label, right.label) || (left.classId ?? '').localeCompare(right.classId ?? ''))
  const classless = byClass.get(null)
  return [
    ...(folder?.length ? [{
      key: groupKey('folder'),
      classId: 'folder',
      label: 'Folder',
      assignments: sortAssignments(folder),
    }] : []),
    ...named,
    ...(classless?.length ? [{
      key: groupKey(null),
      classId: null,
      label: 'Tags',
      assignments: sortAssignments(classless),
    }] : []),
  ]
}

export function folderNameCollision(
  tags: NoteTag[],
  candidate: string,
  parentTagId?: string,
): NoteTag | undefined {
  const normalized = candidate.trim()
  return tags.find((tag) => tag.classId === 'folder'
    && tag.name.trim() === normalized
    && tag.parentTagId === (parentTagId ?? null))
}

export function qualifiedTagLabel(tags: NoteTag[], tagId: string, depthLimit = 64): string {
  return qualifiedTagBreadcrumb(tags, tagId, depthLimit)
    .map((segment) => segment.label)
    .join(' / ')
}

export function matchesCreatedFolder(
  tag: NoteTag,
  classId: string,
  parentTagId?: string,
): boolean {
  return tag.classId === classId && tag.parentTagId === (parentTagId ?? null)
}

export function directFolderAssignments(notebook: { tags: Array<{ tag: NoteTag }> }): NoteTag[] {
  return notebook.tags.map((assignment) => assignment.tag).filter((tag) => tag.classId === 'folder')
}

function catalogGroups(
  tags: NoteTag[],
  classes: NoteTagClass[],
  includeEmptyKnownClasses: boolean,
  locale?: string,
): TagCatalogGroup[] {
  const collator = new Intl.Collator(locale, { sensitivity: 'base' })
  const classesById = new Map(classes.map((tagClass) => [tagClass.classId, tagClass]))
  const nonFolderClassIds = new Set<string>()
  for (const tagClass of classes) {
    if (tagClass.classId !== 'folder') nonFolderClassIds.add(tagClass.classId)
  }
  for (const tag of tags) {
    if (tag.classId && tag.classId !== 'folder') nonFolderClassIds.add(tag.classId)
  }
  const named = [...nonFolderClassIds].map((classId) => {
    const classTags = tags.filter((tag) => tag.classId === classId)
    return {
      key: groupKey(classId),
      classId,
      label: classesById.get(classId)?.label ?? unknownClassLabel(classId),
      tags: tagSorter(locale)(classTags),
      tree: buildTagTree(tags, classId, locale),
      knownClass: classesById.has(classId),
    }
  }).filter((group) => includeEmptyKnownClasses ? group.knownClass || group.tags.length > 0 : group.tags.length > 0)
    .sort((left, right) => collator.compare(left.label, right.label) || left.classId.localeCompare(right.classId))
  const classlessTags = tagSorter(locale)(tags.filter((tag) => tag.classId === null))
  return [
    ...named,
    {
      key: groupKey(null),
      classId: null,
      label: 'Tags',
      tags: classlessTags,
      tree: [],
      knownClass: true,
    },
  ]
}

function tagSorter(locale?: string): (values: NoteTag[]) => NoteTag[] {
  const collator = new Intl.Collator(locale, { sensitivity: 'base' })
  return (values) => [...values].sort((left, right) =>
    collator.compare(left.name, right.name) || left.tagId.localeCompare(right.tagId))
}

function groupKey(classId: string | null): string {
  return classId === null ? 'classless' : `class:${classId}`
}

function unknownClassLabel(classId: string): string {
  return `Unknown class (${classId})`
}
