import { parseMarkdownBlocks, plainInlineText, type MarkdownBlock } from './markdown'

// Heading identity for the reader and the Contents tab. Ids are derived from the
// heading text so a deep link stays readable, and de-duplicated in document
// order so two identically named headings still address different anchors.

export interface HeadingAnchor {
  id: string
  level: number
  text: string
}

export interface HeadingNode extends HeadingAnchor {
  children: HeadingNode[]
}

export function slugifyHeading(text: string): string {
  const slug = plainInlineText(text)
    .toLowerCase()
    .replace(/[^\p{Letter}\p{Number}]+/gu, '-')
    .replace(/^-+|-+$/g, '')
  return slug.length > 0 ? slug : 'section'
}

/** Assigns each heading block its anchor id, suffixing repeats (`intro`,
 * `intro-2`, `intro-3`) so ids stay unique within one rendered document. */
export function headingAnchors(blocks: MarkdownBlock[]): HeadingAnchor[] {
  const used = new Map<string, number>()
  const anchors: HeadingAnchor[] = []
  for (const block of blocks) {
    if (block.kind !== 'heading') continue
    const base = slugifyHeading(block.text)
    const seen = used.get(base) ?? 0
    used.set(base, seen + 1)
    anchors.push({
      id: seen === 0 ? base : `${base}-${seen + 1}`,
      level: Math.min(Math.max(block.level, 1), 6),
      text: plainInlineText(block.text),
    })
  }
  return anchors
}

/** Anchor per block index, so the renderer can hand every heading element the
 * same id the Contents tab links to. */
export function headingAnchorsByBlockIndex(blocks: MarkdownBlock[]): Map<number, HeadingAnchor> {
  const anchors = headingAnchors(blocks)
  const byIndex = new Map<number, HeadingAnchor>()
  let cursor = 0
  blocks.forEach((block, index) => {
    if (block.kind !== 'heading') return
    const anchor = anchors[cursor]
    cursor += 1
    if (anchor) byIndex.set(index, anchor)
  })
  return byIndex
}

/** Nests anchors by level; a heading deeper than its predecessor becomes its
 * child, and a level jump (h1 then h3) never loses the deeper heading. */
export function buildHeadingTree(anchors: HeadingAnchor[]): HeadingNode[] {
  const roots: HeadingNode[] = []
  const stack: HeadingNode[] = []
  for (const anchor of anchors) {
    const node: HeadingNode = { ...anchor, children: [] }
    while (stack.length > 0 && (stack[stack.length - 1]?.level ?? 0) >= node.level) stack.pop()
    const parent = stack[stack.length - 1]
    if (parent) parent.children.push(node)
    else roots.push(node)
    stack.push(node)
  }
  return roots
}

export function markdownHeadingTree(markdown: string): HeadingNode[] {
  return buildHeadingTree(headingAnchors(parseMarkdownBlocks(markdown)))
}

export function flattenHeadingTree(nodes: HeadingNode[]): HeadingAnchor[] {
  return nodes.flatMap((node) => [
    { id: node.id, level: node.level, text: node.text },
    ...flattenHeadingTree(node.children),
  ])
}
