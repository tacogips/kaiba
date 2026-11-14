import { Dynamic } from 'solid-js/web'
import { For, Show, createMemo } from 'solid-js'
import type { JSX } from 'solid-js'
import { isSafeHref, parseInlineSegments, parseMarkdownBlocks } from '../notes/markdown'
import { splitSegmentsByTagTerms, type TagTerm } from '../notes/tagMatch'
import { headingAnchorsByBlockIndex } from '../notes/toc'

// Rendering builds DOM nodes directly from the parsed block model — raw HTML in
// note bodies is never interpreted. Headings render at their authored level with
// the same anchor ids the Contents tab links to. When tag terms are provided,
// occurrences of an attached tag's name inside plain text render as underlined
// clickable terms that open the tag detail pane.

export { parseInlineSegments, parseMarkdownBlocks } from '../notes/markdown'
export type { InlineSegment, MarkdownBlock } from '../notes/markdown'

interface TagDecoration {
  terms?: readonly TagTerm[]
  onTagClick?: (tagId: string) => void
}

function InlineText(props: { text: string } & TagDecoration): JSX.Element {
  const segments = createMemo(() => {
    const parsed = parseInlineSegments(props.text)
    return props.terms?.length ? splitSegmentsByTagTerms(parsed, props.terms) : parsed
  })
  return (
    <For each={segments()}>{(segment) => {
      switch (segment.kind) {
        case 'bold': return <strong>{segment.text}</strong>
        case 'italic': return <em>{segment.text}</em>
        case 'code': return <code class="md-inline-code">{segment.text}</code>
        case 'link':
          return isSafeHref(segment.href)
            ? <a href={segment.href} target="_blank" rel="noopener noreferrer">{segment.text}</a>
            : <span>{segment.text}</span>
        case 'tagTerm':
          return <button
            type="button"
            class="tag-term"
            data-tag-id={segment.tagId}
            title={`Open tag details: ${segment.text}`}
            onClick={() => props.onTagClick?.(segment.tagId)}
          >{segment.text}</button>
        default: return <>{segment.text}</>
      }
    }}</For>
  )
}

export function MarkdownBody(props: {
  markdown: string
  anchorIds?: boolean
  anchorPrefix?: string
  tagTerms?: readonly TagTerm[]
  onTagClick?: (tagId: string) => void
}): JSX.Element {
  const blocks = createMemo(() => parseMarkdownBlocks(props.markdown))
  const anchors = createMemo(() => headingAnchorsByBlockIndex(blocks(), props.anchorPrefix ?? ''))
  return (
    <div class="markdown-body">
      <For each={blocks()}>{(block, index) => {
        switch (block.kind) {
          case 'heading': {
            const level = Math.min(Math.max(block.level, 1), 6)
            // Anchor ids stay unique document-wide: in the continuous reader
            // each note namespaces its anchors with a per-note prefix.
            return <Dynamic
              component={`h${level}`}
              class="md-heading"
              data-md-heading={level}
              id={props.anchorIds === false ? undefined : anchors().get(index())?.id}
            ><InlineText text={block.text} terms={props.tagTerms} onTagClick={props.onTagClick} /></Dynamic>
          }
          case 'code':
            return <pre class="md-code" data-language={block.language ?? undefined}><code>{block.text}</code></pre>
          case 'list':
            return block.ordered
              ? <ol><For each={block.items}>{(item) => <li><InlineText text={item} terms={props.tagTerms} onTagClick={props.onTagClick} /></li>}</For></ol>
              : <ul><For each={block.items}>{(item) => <li><InlineText text={item} terms={props.tagTerms} onTagClick={props.onTagClick} /></li>}</For></ul>
          case 'quote':
            return <blockquote class="md-quote"><InlineText text={block.text} terms={props.tagTerms} onTagClick={props.onTagClick} /></blockquote>
          case 'rule':
            return <hr />
          default:
            return <p class="md-paragraph"><Show when={block.text} fallback={null}><InlineText text={block.text} terms={props.tagTerms} onTagClick={props.onTagClick} /></Show></p>
        }
      }}</For>
    </div>
  )
}
