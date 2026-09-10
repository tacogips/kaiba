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

  test('detects only content that would be lost on reload', () => {
    const drafts = createWritingDrafts()
    const edit = drafts.get('edit:note')
    edit.setText('Current server text')
    edit.setBaseText('Current server text')
    expect(drafts.hasUnsavedChanges()).toBe(false)
    edit.setText('My revision')
    expect(drafts.hasUnsavedChanges()).toBe(true)
    edit.setText('Current server text')
    expect(drafts.hasUnsavedChanges()).toBe(false)

    const discussion = drafts.get('discussion:note')
    discussion.setFiles([new File(['source'], 'source.txt', { type: 'text/plain' })])
    expect(drafts.hasUnsavedChanges()).toBe(true)
    drafts.clear()
    expect(drafts.hasUnsavedChanges()).toBe(false)
  })
})
