import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { noteId, notebookId } from '../notes/ids'
import { PageTagsEditor } from './PageTagsEditor'
import { testDocumentPage } from '../notes/documentPageFixtures'

const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', () => ({ useApp: () => fixture.app }))

test('header tag controls add, replace, and remove assignments on the selected page', async () => {
  const [page, setPage] = createSignal('page-4')
  const apply = vi.fn(async () => {})
  const remove = vi.fn(async () => {})
  const refresh = vi.fn(async () => {})
  fixture.app = { state: { get noteId() { return page() }, tags: [], get note() { return {
    noteId: noteId(page()), notebookId: notebookId('pdf'), noteNumber: 4, readOnly: false, bodyMarkdown: '', createdAt: '', updatedAt: '',
    documentPage: testDocumentPage({ pageNumber: 4, textStatus: 'complete', originFileId: 'file-pdf', analysis: {} }),
    tags: [{ tag: { tagId: 'tag-topic', name: 'Original', classId: 'topic' }, deletable: true }],
  } } }, client: { applyNoteTag: apply, removeNoteTag: remove }, refreshCatalog: refresh, openTagPane: vi.fn() }
  fixture.app.notes = () => [(fixture.app.state as { note: unknown }).note]
  const host = document.createElement('header')
  document.body.append(host)
  const dispose = render(() => <PageTagsEditor />, host)
  const write = (value: string) => {
    const input = host.querySelector('input')!
    input.value = value; input.dispatchEvent(new Event('input', { bubbles: true }))
  }
  const submit = () => host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
  try {
    expect(host.textContent).toContain('Original')
    host.querySelector<HTMLButtonElement>('[aria-label="Add page tag"]')!.click()
    write('Added')
    const add = host.querySelector<HTMLButtonElement>('[aria-label="Add tag"]')!
    expect(add.textContent).toBe('')
    expect(add.querySelector('svg')).not.toBeNull()
    submit()
    await vi.waitFor(() => expect(apply).toHaveBeenCalledWith('page-4', 'Added', undefined))
    await vi.waitFor(() => expect(host.querySelector('form')).toBeNull())
    host.querySelector<HTMLButtonElement>('[aria-label="Edit tag Original"]')!.click()
    write('Replacement'); submit()
    await vi.waitFor(() => expect(remove).toHaveBeenCalledWith('page-4', 'Original'))
    expect(apply).toHaveBeenLastCalledWith('page-4', 'Replacement', 'topic')
    await vi.waitFor(() => expect(host.querySelector('form')).toBeNull())
    setPage('page-5')
    expect(host.querySelector('input')).toBeNull()
    host.querySelector<HTMLButtonElement>('[aria-label="Remove tag Original"]')!.click()
    await vi.waitFor(() => expect(remove).toHaveBeenLastCalledWith('page-5', 'Original'))
    expect(refresh).toHaveBeenCalled()
  } finally { dispose(); host.remove() }
})


test('tag names open occurrences and navigate through central return-aware navigation; typed tags preserve ontology', async () => {
  const existingTag = { tagId: 'tag-person', name: 'Ada', classId: 'person', parentTagId: null }
  const source = { noteId: noteId('source'), notebookId: notebookId('pdf'), noteNumber: 1, title: 'Source',
    bodyMarkdown: '', documentPage: testDocumentPage({ pageNumber: 1, textStatus: 'complete', originFileId: 'file-pdf', analysis: {} }),
    tags: [{ tag: existingTag, deletable: true }] }
  const result = { ...source, noteId: noteId('result'), notebookId: notebookId('other'), title: 'Matching page', noteNumber: 7 }
  const occurrences = vi.fn(async () => [result])
  const apply = vi.fn(async () => {})
  const navigate = vi.fn()
  fixture.app = { state: { noteId: source.noteId, note: source, tags: [existingTag],
    tagClasses: [{ classId: 'person', label: 'Person' }, { classId: 'date', label: 'Date' }, { classId: 'place', label: 'Place' }],
    notebooks: [{ notebookId: 'other', title: 'Other document' }] }, notes: () => [source],
    client: { notesByTag: occurrences, applyNoteTag: apply }, refreshCatalog: async () => {}, openNoteWithReturn: navigate }
  const host = document.createElement('header')
  document.body.append(host)
  const dispose = render(() => <PageTagsEditor />, host)
  try {
    host.querySelector<HTMLButtonElement>('.tag-chip-open')!.click()
    await vi.waitFor(() => expect(occurrences).toHaveBeenCalledWith('Ada', 0, 50))
    const popup = document.querySelector('[aria-label="Notes tagged Ada"]')!
    expect(popup.textContent).toContain('Other document')
    const match = [...popup.querySelectorAll('button')].find((button) => button.textContent?.includes('Matching page'))!
    match.click()
    expect(navigate).toHaveBeenCalledWith('result', 'other')
    expect(document.querySelector('[aria-label="Notes tagged Ada"]')).toBeNull()
    host.querySelector<HTMLButtonElement>('[aria-label="Add page tag"]')!.click()
    const input = host.querySelector('input')!
    input.value = '2026-10-24'; input.dispatchEvent(new Event('input', { bubbles: true }))
    const type = host.querySelector('select')!
    type.value = 'date'; type.dispatchEvent(new Event('change', { bubbles: true }))
    expect(input.type).toBe('date')
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await vi.waitFor(() => expect(apply).toHaveBeenCalledWith('source', '2026-10-24', 'date'))
    await vi.waitFor(() => expect(host.querySelector('form')).toBeNull())
    host.querySelector<HTMLButtonElement>('[aria-label="Add page tag"]')!.click()
    const name = host.querySelector('input')!
    name.value = 'Ada'; name.dispatchEvent(new Event('input', { bubbles: true }))
    expect(host.querySelector('select')!.value).toBe('person')
    expect(host.querySelector('select')!.disabled).toBe(true)
    expect(host.textContent).toContain('Existing tag')
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await vi.waitFor(() => expect(apply).toHaveBeenLastCalledWith('source', 'Ada', 'person'))
  } finally { dispose(); host.remove() }
})

test.each([
  ['date', '2026-10-24'], ['name', 'Ada Lovelace'], ['place', 'Kyoto'],
])('new %s tags submit their ontology class with the free-input value', async (classId, value) => {
  const apply = vi.fn(async () => {})
  const source = { noteId: noteId('source'), notebookId: notebookId('pdf'), noteNumber: 1, tags: [],
    documentPage: testDocumentPage({ pageNumber: 1, textStatus: 'complete', originFileId: 'file-pdf', analysis: {} }) }
  fixture.app = { state: { noteId: source.noteId, note: source, tags: [],
    tagClasses: [{ classId: 'date', label: 'Date' }, { classId: 'name', label: 'Name' }, { classId: 'place', label: 'Place' }] },
    notes: () => [source], client: { applyNoteTag: apply }, refreshCatalog: async () => {} }
  const host = document.createElement('header')
  document.body.append(host)
  const dispose = render(() => <PageTagsEditor />, host)
  try {
    host.querySelector<HTMLButtonElement>('[aria-label="Add page tag"]')!.click()
    const type = host.querySelector('select')!
    type.value = classId; type.dispatchEvent(new Event('change', { bubbles: true }))
    const input = host.querySelector('input')!
    expect(input.type).toBe(classId === 'date' ? 'date' : 'text')
    input.value = value; input.dispatchEvent(new Event('input', { bubbles: true }))
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await vi.waitFor(() => expect(apply).toHaveBeenCalledWith('source', value, classId))
  } finally { dispose(); host.remove() }
})
