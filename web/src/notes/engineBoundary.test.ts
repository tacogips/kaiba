import { readdirSync, readFileSync } from 'node:fs'
import { relative, resolve } from 'node:path'
import { describe, expect, test } from 'bun:test'

const sourceRoot = resolve(import.meta.dir, '..')

function sourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(directory, entry.name)
    return entry.isDirectory() ? sourceFiles(path) : [path]
  })
}

describe('web search engine boundary', () => {
  test('source contains no engine coordinates or server environment name', () => {
    const files = sourceFiles(sourceRoot)
    expect(files.some((path) => path.endsWith('notes/client.ts'))).toBe(true)

    const forbidden = [
      String(77 * 100),
      ['default', 'URL'].join(''),
      ['KAIBA', 'MEILISEARCH', 'URL'].join('_'),
    ]
    const findings = files.flatMap((path) => {
      const lines = readFileSync(path, 'utf8').split(/\r?\n/)
      return lines.flatMap((line, index) => forbidden.some((needle) => line.includes(needle))
        ? [`${relative(sourceRoot, path)}:${index + 1}`]
        : [])
    })

    expect(findings).toEqual([])
  })
})
