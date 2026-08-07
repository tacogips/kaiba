import { For, Show } from 'solid-js'
import type { JSX } from 'solid-js'

// Block-level markdown model mirroring the native RielaNoteMarkdownBodyView:
// headings, fenced code, lists, quotes, rules, and paragraphs, with a small
// inline grammar (bold, italic, inline code, links). Rendering builds DOM
// nodes directly — raw HTML in note bodies is never interpreted.

export type MarkdownBlock =
  | { kind: 'heading'; level: number; text: string }
  | { kind: 'code'; text: string; language: string | null }
  | { kind: 'list'; items: string[]; ordered: boolean }
  | { kind: 'quote'; text: string }
  | { kind: 'rule' }
  | { kind: 'paragraph'; text: string }

export function parseMarkdownBlocks(markdown: string): MarkdownBlock[] {
  const blocks: MarkdownBlock[] = []
  const lines = markdown.replace(/\r\n/g, '\n').split('\n')
  let index = 0
  let paragraph: string[] = []
  const flushParagraph = () => {
    const text = paragraph.join('\n').trim()
    paragraph = []
    if (text) blocks.push({ kind: 'paragraph', text })
  }
  while (index < lines.length) {
    const line = lines[index] ?? ''
    const trimmed = line.trim()
    const fence = /^(```|~~~)\s*(\S*)\s*$/.exec(trimmed)
    if (fence) {
      flushParagraph()
      const marker = fence[1] ?? '```'
      const language = fence[2] || null
      const buffer: string[] = []
      index += 1
      while (index < lines.length && !(lines[index] ?? '').trim().startsWith(marker)) {
        buffer.push(lines[index] ?? '')
        index += 1
      }
      index += 1
      blocks.push({ kind: 'code', text: buffer.join('\n'), language })
      continue
    }
    if (!trimmed) {
      flushParagraph()
      index += 1
      continue
    }
    const heading = /^(#{1,6})\s+(.*)$/.exec(trimmed)
    if (heading) {
      flushParagraph()
      blocks.push({ kind: 'heading', level: (heading[1] ?? '#').length, text: heading[2] ?? '' })
      index += 1
      continue
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      flushParagraph()
      blocks.push({ kind: 'rule' })
      index += 1
      continue
    }
    if (trimmed.startsWith('>')) {
      flushParagraph()
      const buffer: string[] = []
      while (index < lines.length && (lines[index] ?? '').trim().startsWith('>')) {
        buffer.push((lines[index] ?? '').trim().replace(/^>\s?/, ''))
        index += 1
      }
      blocks.push({ kind: 'quote', text: buffer.join('\n') })
      continue
    }
    const unordered = /^[-*+]\s+/.test(trimmed)
    const ordered = /^\d+[.)]\s+/.test(trimmed)
    if (unordered || ordered) {
      flushParagraph()
      const items: string[] = []
      const matcher = unordered ? /^[-*+]\s+(.*)$/ : /^\d+[.)]\s+(.*)$/
      while (index < lines.length) {
        const itemLine = (lines[index] ?? '').trim()
        const match = matcher.exec(itemLine)
        if (!match) break
        items.push(match[1] ?? '')
        index += 1
      }
      blocks.push({ kind: 'list', items, ordered })
      continue
    }
    paragraph.push(line)
    index += 1
  }
  flushParagraph()
  return blocks
}

type InlineSegment =
  | { kind: 'text'; text: string }
  | { kind: 'bold'; text: string }
  | { kind: 'italic'; text: string }
  | { kind: 'code'; text: string }
  | { kind: 'link'; text: string; href: string }

export function parseInlineSegments(text: string): InlineSegment[] {
  const segments: InlineSegment[] = []
  const pattern = /(`[^`]+`)|(\*\*[^*]+\*\*)|(__[^_]+__)|(\*[^*\s][^*]*\*)|(_[^_\s][^_]*_)|(\[([^\]]+)\]\(([^)\s]+)\))/g
  let cursor = 0
  for (let match = pattern.exec(text); match; match = pattern.exec(text)) {
    if (match.index > cursor) segments.push({ kind: 'text', text: text.slice(cursor, match.index) })
    const token = match[0] ?? ''
    if (token.startsWith('`')) {
      segments.push({ kind: 'code', text: token.slice(1, -1) })
    } else if (token.startsWith('**') || token.startsWith('__')) {
      segments.push({ kind: 'bold', text: token.slice(2, -2) })
    } else if (token.startsWith('[') && match[7] !== undefined && match[8] !== undefined) {
      segments.push({ kind: 'link', text: match[7], href: match[8] })
    } else {
      segments.push({ kind: 'italic', text: token.slice(1, -1) })
    }
    cursor = match.index + token.length
  }
  if (cursor < text.length) segments.push({ kind: 'text', text: text.slice(cursor) })
  return segments
}

function isSafeHref(href: string): boolean {
  return /^(https?:|mailto:|#|\/)/i.test(href)
}

function InlineText(props: { text: string }): JSX.Element {
  return (
    <For each={parseInlineSegments(props.text)}>{(segment) => {
      switch (segment.kind) {
        case 'bold': return <strong>{segment.text}</strong>
        case 'italic': return <em>{segment.text}</em>
        case 'code': return <code class="md-inline-code">{segment.text}</code>
        case 'link':
          return isSafeHref(segment.href)
            ? <a href={segment.href} target="_blank" rel="noopener noreferrer">{segment.text}</a>
            : <span>{segment.text}</span>
        default: return <>{segment.text}</>
      }
    }}</For>
  )
}

export function MarkdownBody(props: { markdown: string }): JSX.Element {
  return (
    <div class="markdown-body">
      <For each={parseMarkdownBlocks(props.markdown)}>{(block) => {
        switch (block.kind) {
          case 'heading': {
            const level = Math.min(Math.max(block.level, 1), 6)
            return level <= 1
              ? <h3 class="md-heading"><InlineText text={block.text} /></h3>
              : <h4 class="md-heading"><InlineText text={block.text} /></h4>
          }
          case 'code':
            return <pre class="md-code" data-language={block.language ?? undefined}><code>{block.text}</code></pre>
          case 'list':
            return block.ordered
              ? <ol><For each={block.items}>{(item) => <li><InlineText text={item} /></li>}</For></ol>
              : <ul><For each={block.items}>{(item) => <li><InlineText text={item} /></li>}</For></ul>
          case 'quote':
            return <blockquote class="md-quote"><InlineText text={block.text} /></blockquote>
          case 'rule':
            return <hr />
          default:
            return <p class="md-paragraph"><Show when={block.text} fallback={null}><InlineText text={block.text} /></Show></p>
        }
      }}</For>
    </div>
  )
}
