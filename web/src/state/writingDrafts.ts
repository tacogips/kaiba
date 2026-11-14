import { createSignal } from 'solid-js'

/** Session-only drafts belong to one app store. They never enter shared settings. */
export function createWritingDrafts() {
  const drafts = new Map<string, ReturnType<typeof createWritingDraft>>()
  return {
    get(key: string) {
      let draft = drafts.get(key)
      if (!draft) {
        draft = createWritingDraft()
        drafts.set(key, draft)
      }
      return draft
    },
    clear() {
      for (const draft of drafts.values()) draft.setText('')
      for (const draft of drafts.values()) draft.setFiles([])
      for (const draft of drafts.values()) draft.setBaseText(undefined)
      drafts.clear()
    },
  }
}

function createWritingDraft() {
  const [text, setText] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  const [files, setFiles] = createSignal<File[]>([])
  const [memoOnly, setMemoOnly] = createSignal(false)
  const [baseText, setBaseText] = createSignal<string>()
  return { text, setText, busy, setBusy, error, setError, files, setFiles, memoOnly, setMemoOnly, baseText, setBaseText }
}
