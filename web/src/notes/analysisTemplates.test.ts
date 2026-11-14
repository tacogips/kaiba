import { describe, expect, test } from 'bun:test'
import { analysisPrompt, parseAnalysisTemplates } from './analysisTemplates'
import { parseWebSettings, serializeWebSettings } from './settings'

describe('analysis templates', () => {
  test('round-trips custom templates with other persisted preferences', () => {
    const settings = { fontScale: 1.2, agentProvider: 'ollama', agentModel: 'local', analysisTemplates: [
      { id: 'custom-1', name: 'Literature review', prompt: 'Extract methods and limitations.' },
    ] }
    expect(parseWebSettings(serializeWebSettings(settings))).toEqual(settings)
    expect(parseWebSettings(serializeWebSettings({ ...settings, analysisTemplates: [] })).analysisTemplates).toBeUndefined()
  })

  test('rejects malformed, duplicate, oversized and built-in-shadowing records', () => {
    const valid = { id: 'mine', name: 'Mine', prompt: 'Analyze' }
    expect(parseAnalysisTemplates([null, 'bad', {}, valid, valid,
      { ...valid, id: 'summary' }, { ...valid, id: 'custom' }, { ...valid, id: 'long', prompt: 'x'.repeat(10001) },
      { ...valid, id: 'blank', name: ' ' },
    ])).toEqual([valid])
    expect(parseAnalysisTemplates({})).toEqual([])
  })

  test('records the template and requests source-grounded, non-editing output', () => {
    const result = analysisPrompt({ name: ' Methods ', prompt: ' Explain the method. ' })
    expect(result).toStartWith('# Analysis: Methods\n\nExplain the method.')
    expect(result).toContain('Cite the source note number')
    expect(result).toContain('without modifying the source')
  })
})
