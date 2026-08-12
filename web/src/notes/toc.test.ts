import { describe, expect, test } from 'bun:test'
import { parseMarkdownBlocks } from './markdown'
import {
  buildHeadingTree,
  flattenHeadingTree,
  headingAnchors,
  headingAnchorsByBlockIndex,
  markdownHeadingTree,
  noteHeadingPrefix,
  slugifyHeading,
} from './toc'

describe('heading slugs', () => {
  test('lowercases, strips inline markup and collapses punctuation', () => {
    expect(slugifyHeading('Design **Decisions**: W1 — W8')).toBe('design-decisions-w1-w8')
    expect(slugifyHeading('`kaiba serve` notes')).toBe('kaiba-serve-notes')
    expect(slugifyHeading('[Link](https://example.com) target')).toBe('link-target')
  })

  test('keeps non-latin headings addressable and falls back for empty slugs', () => {
    expect(slugifyHeading('設計メモ')).toBe('設計メモ')
    expect(slugifyHeading('***')).toBe('section')
  })

  test('de-duplicates repeated headings in document order', () => {
    const anchors = headingAnchors(parseMarkdownBlocks('# Notes\n\n## Notes\n\n## Notes\n'))
    expect(anchors.map((anchor) => anchor.id)).toEqual(['notes', 'notes-2', 'notes-3'])
  })

  test('a note prefix namespaces every anchor so notes never collide in the reader', () => {
    const prefix = noteHeadingPrefix('n-42')
    const anchors = headingAnchors(parseMarkdownBlocks('# Notes\n\n## Notes\n'), prefix)
    expect(anchors.map((anchor) => anchor.id)).toEqual(['note-n-42--notes', 'note-n-42--notes-2'])
    const tree = markdownHeadingTree('# Notes\n', noteHeadingPrefix('other'))
    expect(tree[0]?.id).toBe('note-other--notes')
  })

  test('prefixed block-index anchors match the prefixed anchor list', () => {
    const blocks = parseMarkdownBlocks('# One\n\ntext\n\n## Two\n')
    const byIndex = headingAnchorsByBlockIndex(blocks, noteHeadingPrefix('x'))
    expect(byIndex.get(0)?.id).toBe('note-x--one')
    expect(byIndex.get(2)?.id).toBe('note-x--two')
  })

  test('maps anchors back to their block index so the renderer and the TOC agree', () => {
    const blocks = parseMarkdownBlocks('intro\n\n# One\n\ntext\n\n## Two\n')
    const byIndex = headingAnchorsByBlockIndex(blocks)
    expect([...byIndex.keys()]).toEqual([1, 3])
    expect(byIndex.get(1)?.id).toBe('one')
    expect(byIndex.get(3)?.id).toBe('two')
  })
})

describe('heading tree', () => {
  test('nests deeper headings under the preceding shallower heading', () => {
    const tree = markdownHeadingTree('# One\n\n## One A\n\n### One A i\n\n## One B\n\n# Two\n')
    expect(tree.map((node) => node.text)).toEqual(['One', 'Two'])
    expect(tree[0]?.children.map((node) => node.text)).toEqual(['One A', 'One B'])
    expect(tree[0]?.children[0]?.children.map((node) => node.text)).toEqual(['One A i'])
  })

  test('keeps a heading that skips a level and a document starting deep', () => {
    const tree = markdownHeadingTree('### Deep start\n\n# Later root\n\n### Skipped\n')
    expect(tree.map((node) => node.text)).toEqual(['Deep start', 'Later root'])
    expect(tree[1]?.children.map((node) => node.text)).toEqual(['Skipped'])
  })

  test('flattening restores document order', () => {
    const anchors = headingAnchors(parseMarkdownBlocks('# A\n\n## B\n\n# C\n'))
    expect(flattenHeadingTree(buildHeadingTree(anchors)).map((anchor) => anchor.id))
      .toEqual(['a', 'b', 'c'])
  })

  test('a document without headings has an empty tree', () => {
    expect(markdownHeadingTree('plain paragraph only')).toEqual([])
  })
})
