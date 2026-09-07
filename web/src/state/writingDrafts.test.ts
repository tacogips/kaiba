import { describe, expect, test } from 'bun:test'
import { createWritingDrafts } from './writingDrafts'

describe('session writing drafts', () => {
  test('restores each notebook independently, including an in-flight save', () => {
    const drafts = createWritingDrafts()
    const first = drafts.get('note:first')
    first.setText('My explanation')
    first.setBusy(true)
    drafts.get('note:second').setText('A different thought')
    expect(drafts.get('note:first').text()).toBe('My explanation')
    expect(drafts.get('note:first').busy()).toBe(true)
    expect(drafts.get('note:second').text()).toBe('A different thought')
  })

  test('never shares writing between app sessions and clears live references on sign-out', () => {
    const drafts = createWritingDrafts()
    const old = drafts.get('note:first')
    old.setText('Private thought')
    expect(createWritingDrafts().get('note:first').text()).toBe('')
    drafts.clear()
    expect(old.text()).toBe('')
    expect(drafts.get('note:first').text()).toBe('')
  })
})
