import { describe, expect, test } from 'bun:test'
import {
  assignableTagGroups,
  buildFolderTree,
  buildTagTree,
  folderBreadcrumb,
  folderNameCollision,
  groupTagAssignments,
  matchesCreatedFolder,
  navigationTagGroups,
  qualifiedTagBreadcrumb,
  qualifiedTagLabel,
  tagBreadcrumb,
} from './tree'
import type { NoteTag, NoteTagAssignment, NoteTagClass } from './types'

const tag = (tagId: string, name: string, parentTagId: string | null = null, classId: string | null = 'folder'): NoteTag => ({
  tagId,
  name,
  parentTagId,
  classId,
  isSystem: false,
  createdAt: '2026-07-25T00:00:00Z',
})
const classes: NoteTagClass[] = [
  { classId: 'folder', label: 'Folder', description: null },
  { classId: 'topic', label: 'Topic', description: null },
  { classId: 'priority', label: 'Priority', description: null },
  { classId: 'empty', label: 'Empty', description: null },
]
const assignment = (value: NoteTag, deletable = true): NoteTagAssignment => ({
  tag: value,
  provenance: 'human',
  assignedBy: 'kaiba-web',
  deletable,
  createdAt: '2026-07-25T00:00:00Z',
})

describe('folder tree', () => {
  test('builds arbitrary depth and promotes invalid parents', () => {
    const tags = [
      tag('root', 'Work'),
      tag('child', 'Project', 'root'),
      tag('grandchild', 'Launch', 'child'),
      tag('orphan', 'Archive', 'missing'),
      tag('topic', 'Not a folder', null, 'topic'),
    ]
    const tree = buildFolderTree(tags, 'en')
    expect(tree.map((node) => node.tag.name)).toEqual(['Archive', 'Work'])
    expect(tree[1]?.children[0]?.children[0]?.tag.name).toBe('Launch')
    expect(folderBreadcrumb(tags, 'grandchild').map((value) => value.name)).toEqual(['Work', 'Project', 'Launch'])
  })

  test('terminates malformed cycles and detects sibling-only trimmed-name collisions', () => {
    const tags = [
      tag('one', 'One', 'two'),
      tag('two', 'Two', 'one'),
      tag('root-a', 'A'),
      tag('root-b', 'B'),
      tag('child-a', ' Shared ', 'root-a'),
      tag('child-b', 'Shared', 'root-b'),
      tag('topic', 'Shared', null, 'topic'),
    ]
    const tree = buildFolderTree(tags, 'en')
    expect(tree.length).toBeGreaterThan(0)
    expect(folderNameCollision(tags, 'Shared')).toBeUndefined()
    expect(folderNameCollision(tags, 'Shared', 'root-a')?.tagId).toBe('child-a')
    expect(folderNameCollision(tags, 'Shared', 'root-b')?.tagId).toBe('child-b')
    expect(qualifiedTagLabel(tags, 'child-a')).toBe('A /  Shared ')
    expect(qualifiedTagLabel(tags, 'missing')).toBe('[missing: missing]')
    expect(qualifiedTagLabel(tags, 'one')).toContain('[cycle:')
    expect(qualifiedTagBreadcrumb(tags, 'child-a').map((segment) => segment.label))
      .toEqual(['A', ' Shared '])
    expect(qualifiedTagBreadcrumb(tags, 'one').map((segment) => segment.label))
      .toEqual(['[cycle: one]', 'Two', 'One'])
    expect(qualifiedTagBreadcrumb([
      tag('orphan', 'Orphan', 'absent'),
    ], 'orphan').map((segment) => segment.label))
      .toEqual(['[missing: absent]', 'Orphan'])
    expect(qualifiedTagBreadcrumb([
      tag('topic-child', 'Child', 'missing-topic', 'topic'),
    ], 'topic-child').map((segment) => segment.label))
      .toEqual(['[missing: missing-topic]', 'Child'])
    expect(qualifiedTagBreadcrumb(tags, 'child-a', 1).map((segment) => segment.label))
      .toEqual(['[depth: child-a]', ' Shared '])
  })

  test('validates the authoritative class and parent returned for creation', () => {
    expect(matchesCreatedFolder(tag('child', 'Child', 'root'), 'folder', 'root')).toBe(true)
    expect(matchesCreatedFolder(tag('child', 'Child', 'other'), 'folder', 'root')).toBe(false)
    expect(matchesCreatedFolder(tag('root', 'Root'), 'folder')).toBe(true)
    expect(matchesCreatedFolder(tag('topic', 'Topic', null, 'topic'), 'folder')).toBe(false)
  })

  test('builds class-scoped trees without following cross-class parents', () => {
    const tags = [
      tag('topic-root', 'Product', null, 'topic'),
      tag('topic-child', 'Launch', 'topic-root', 'topic'),
      tag('topic-grandchild', 'Web', 'topic-child', 'topic'),
      tag('priority', 'High', 'topic-root', 'priority'),
    ]
    const topicTree = buildTagTree(tags, 'topic', 'en')
    const priorityTree = buildTagTree(tags, 'priority', 'en')
    expect(topicTree[0]?.children[0]?.children[0]?.tag.name).toBe('Web')
    expect(priorityTree.map((node) => node.tag.name)).toEqual(['High'])
    expect(tagBreadcrumb(tags, 'topic-grandchild', 'topic').map((value) => value.name))
      .toEqual(['Product', 'Launch', 'Web'])
  })

  test('orders named classes and keeps classless tags last and flat', () => {
    const tags = [
      tag('topic', 'Product', null, 'topic'),
      tag('priority', 'High', null, 'priority'),
      tag('classless-child', 'Loose child', 'classless-root', null),
      tag('classless-root', 'Loose root', null, null),
    ]
    const groups = navigationTagGroups(tags, classes, 'en')
    expect(groups.map((group) => group.label)).toEqual(['Priority', 'Topic', 'Tags'])
    expect(groups.at(-1)?.tree).toEqual([])
    expect(groups.at(-1)?.tags.map((value) => value.name)).toEqual(['Loose child', 'Loose root'])
    expect(assignableTagGroups(tags, classes, 'en').map((group) => group.label))
      .toEqual(['Empty', 'Priority', 'Topic', 'Tags'])
  })

  test('groups assignments with folder first, unknown classes visible, and classless last', () => {
    const groups = groupTagAssignments([
      assignment(tag('loose', 'Loose', null, null)),
      assignment(tag('topic', 'Product', null, 'topic')),
      assignment(tag('unknown', 'Legacy', null, 'legacy')),
      assignment(tag('folder', 'Work')),
    ], classes, 'en')
    expect(groups.map((group) => group.label)).toEqual([
      'Folder',
      'Topic',
      'Unknown class (legacy)',
      'Tags',
    ])
  })
})
