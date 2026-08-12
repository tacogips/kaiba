import { Dynamic } from 'solid-js/web'
import { For, Show, createMemo } from 'solid-js'
import type { JSX } from 'solid-js'
import { isSafeHref, parseInlineSegments, parseMarkdownBlocks } from '../notes/markdown'
import { headingAnchorsByBlockIndex } from '../notes/toc'

// Rendering builds DOM nodes directly from the parsed block model — raw HTML in
// note bodies is never interpreted. Headings render at their authored level with
// the same anchor ids the Contents tab links to.

export { parseInlineSegments, parseMarkdownBlocks } from '../notes/markdown'
export type { InlineSegment, MarkdownBlock } from '../notes/markdown'

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
  const blocks = createMemo(() => parseMarkdownBlocks(props.markdown))
  const anchors = createMemo(() => headingAnchorsByBlockIndex(blocks()))
  return (
    <div class="markdown-body">
      <For each={blocks()}>{(block, index) => {
        switch (block.kind) {
          case 'heading': {
            const level = Math.min(Math.max(block.level, 1), 6)
            return <Dynamic
              component={`h${level}`}
              class="md-heading"
              data-md-heading={level}
              id={anchors().get(index())?.id}
            ><InlineText text={block.text} /></Dynamic>
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
