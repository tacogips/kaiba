export interface NotebookDraftNote {
  bodyMarkdown: string
  title: string
  startOffset: number
  endOffset: number
}

/** A standalone, unescaped <><> starts a new note outside fenced code. */
export function parseNotebookDraft(source: string): { title: string; notes: NotebookDraftNote[]; fenceOpen: boolean } {
  const notes: NotebookDraftNote[] = []
  let start = 0
  let fence: { character: string; length: number } | undefined
  const append = (end: number) => {
    const bodyMarkdown = source.slice(start, end).replace(/^(?:[\t ]*\r?\n)+/, '').replace(/(?:\r?\n[\t ]*)+$/, '')
    notes.push({ bodyMarkdown, title: firstLineTitle(bodyMarkdown), startOffset: start, endOffset: end })
  }
  for (const match of source.matchAll(/[^\n]*(?:\n|$)/g)) {
    if (!match[0]) continue
    const line = match[0].replace(/\r?\n$/, '')
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line)
    if (fence) {
      if (marker && marker[1]![0] === fence.character && marker[1]!.length >= fence.length && !marker[2]!.trim()) fence = undefined
      continue
    }
    if (marker) { fence = { character: marker[1]![0]!, length: marker[1]!.length }; continue }
    if (/^ {0,3}<><>[\t ]*$/.test(line)) {
      append(match.index)
      start = match.index + match[0].length
    }
  }
  append(source.length)
  return { title: notes[0]?.title ?? '', notes, fenceOpen: Boolean(fence) }
}

function firstLineTitle(body: string): string {
  return (body.split(/\r?\n/, 1)[0] ?? '').replace(/^ {0,3}#{1,6}[\t ]+/, '').replace(/[\t ]+#+[\t ]*$/, '').trim()
}
