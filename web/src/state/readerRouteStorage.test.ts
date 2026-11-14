import { expect, test } from 'bun:test'
import { readReaderRoute, writeReaderRoute } from './readerRouteStorage'
import { noteId, notebookId } from '../notes/ids'

test('a Settings reload retains the full reader context without restoring Settings as its destination', () => {
  const values = new Map<string, string>()
  const storage = { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => { values.set(key, value) } }
  const source = { kind: 'note' as const, noteId: noteId('page-7'), conversationId: notebookId('chat') }
  writeReaderRoute(source, storage)
  expect(readReaderRoute(storage)).toEqual(source)
  writeReaderRoute({ kind: 'config' }, storage)
  expect(readReaderRoute(storage)).toEqual({ kind: 'home' })
})

test('unavailable or corrupt storage leaves a usable reader destination', () => {
  expect(readReaderRoute({ getItem: () => { throw new Error('denied') }, setItem: () => {} })).toEqual({ kind: 'home' })
  expect(readReaderRoute({ getItem: () => 'invalid', setItem: () => {} })).toEqual({ kind: 'home' })
})
