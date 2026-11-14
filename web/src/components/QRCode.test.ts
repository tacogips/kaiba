import { describe, expect, test } from 'bun:test'
import {
  QRCodeError,
  alignmentPatternPositions,
  dataCodewordCount,
  darkModuleRuns,
  encodeQRCode,
  rawDataModuleCount,
  smallestVersionFor,
  totalCodewordCount,
} from './QRCode'

const QUIET_ZONE = 4

// Verified out-of-band: rendering this matrix and decoding it with Apple's Vision
// QR detector returns exactly "riela". Locks the encoder against silent drift.
const RIELA_V1_ROWS = [
  '111111100111001111111',
  '100000101100101000001',
  '101110101110101011101',
  '101110101101001011101',
  '101110100100101011101',
  '100000100101001000001',
  '111111101010101111111',
  '000000001010000000000',
  '100000101111011001110',
  '001011011101110110000',
  '010111101010101101110',
  '001100001011111101101',
  '010110110111111111011',
  '000000001100100001111',
  '111111100111010011110',
  '100000100000001001111',
  '101110100011010010010',
  '101110100011111001000',
  '101110100111110111111',
  '100000100101111101100',
  '111111101000100100010',
]

function rowsOf(matrix: { size: number; modules: Uint8Array }): string[] {
  const rows: string[] = []
  for (let y = 0; y < matrix.size; y++) {
    let row = ''
    for (let x = 0; x < matrix.size; x++) row += matrix.modules[y * matrix.size + x] === 1 ? '1' : '0'
    rows.push(row)
  }
  return rows
}

function moduleAt(matrix: { size: number; modules: Uint8Array }, x: number, y: number): number {
  return matrix.modules[y * matrix.size + x] ?? -1
}

describe('QR capacity tables', () => {
  test('derives codeword counts that match the level-M specification', () => {
    expect(rawDataModuleCount(1)).toBe(208)
    expect(totalCodewordCount(1)).toBe(26)
    expect(dataCodewordCount(1)).toBe(16)
    expect(totalCodewordCount(13)).toBe(532)
    expect(dataCodewordCount(13)).toBe(334)
    expect(totalCodewordCount(40)).toBe(3706)
    expect(dataCodewordCount(40)).toBe(2334)
  })

  test('block structure never exceeds the version capacity', () => {
    for (let version = 1; version <= 40; version++) {
      expect(dataCodewordCount(version)).toBeGreaterThan(0)
      expect(dataCodewordCount(version)).toBeLessThan(totalCodewordCount(version))
    }
  })

  test('selects the smallest version that fits a byte payload', () => {
    expect(smallestVersionFor(1)).toBe(1)
    expect(smallestVersionFor(14)).toBe(1)
    expect(smallestVersionFor(15)).toBe(2)
    // A ~250-character registration URL must stay well inside version 13.
    expect(smallestVersionFor(250)).toBeLessThanOrEqual(13)
    expect(() => smallestVersionFor(3000)).toThrow(QRCodeError)
  })
})

describe('QR alignment patterns', () => {
  test('matches the standard centre coordinates', () => {
    expect(alignmentPatternPositions(1)).toEqual([])
    expect(alignmentPatternPositions(2)).toEqual([6, 18])
    expect(alignmentPatternPositions(7)).toEqual([6, 22, 38])
    expect(alignmentPatternPositions(32)).toEqual([6, 34, 60, 86, 112, 138])
  })
})

describe('QR encoding', () => {
  test('reproduces a verified version-1 matrix', () => {
    const matrix = encodeQRCode('riela')
    expect(matrix.version).toBe(1)
    expect(matrix.size).toBe(21)
    expect(matrix.mask).toBe(5)
    expect(rowsOf(matrix)).toEqual(RIELA_V1_ROWS)
  })

  test('places finder patterns in three corners with separators', () => {
    const matrix = encodeQRCode('https://127.0.0.1:19091/note-api/register?code=ABC123')
    const size = matrix.size
    for (const [originX, originY] of [[0, 0], [size - 7, 0], [0, size - 7]] as const) {
      for (let dy = 0; dy < 7; dy++) {
        for (let dx = 0; dx < 7; dx++) {
          const ring = Math.max(Math.abs(dx - 3), Math.abs(dy - 3))
          expect(moduleAt(matrix, originX + dx, originY + dy)).toBe(ring === 2 ? 0 : 1)
        }
      }
    }
    // The bottom-right corner carries a 5x5 alignment pattern, not a fourth finder.
    for (let dy = -2; dy <= 2; dy++) {
      for (let dx = -2; dx <= 2; dx++) {
        const ring = Math.max(Math.abs(dx), Math.abs(dy))
        expect(moduleAt(matrix, size - 7 + dx, size - 7 + dy)).toBe(ring === 1 ? 0 : 1)
      }
    }
    // Separator row/column around the top-left finder is always light.
    for (let index = 0; index < 8; index++) {
      expect(moduleAt(matrix, index, 7)).toBe(0)
      expect(moduleAt(matrix, 7, index)).toBe(0)
    }
  })

  test('draws alternating timing patterns and the fixed dark module', () => {
    const matrix = encodeQRCode('https://127.0.0.1:19091/note-api/register?code=ABC123')
    for (let index = 8; index < matrix.size - 8; index++) {
      expect(moduleAt(matrix, index, 6)).toBe(index % 2 === 0 ? 1 : 0)
      expect(moduleAt(matrix, 6, index)).toBe(index % 2 === 0 ? 1 : 0)
    }
    expect(moduleAt(matrix, 8, matrix.size - 8)).toBe(1)
  })

  test('grows the version with the payload and stays square', () => {
    const short = encodeQRCode('a')
    const long = encodeQRCode('a'.repeat(240))
    expect(short.version).toBe(1)
    expect(long.version).toBeGreaterThan(short.version)
    expect(long.version).toBeLessThanOrEqual(13)
    expect(long.size).toBe(long.version * 4 + 17)
    expect(long.modules.length).toBe(long.size * long.size)
  })

  test('encodes multi-byte characters by UTF-8 length', () => {
    const matrix = encodeQRCode('日本語のノート')
    expect(matrix.size).toBe(matrix.version * 4 + 17)
    expect(matrix.modules.some((value) => value === 1)).toBe(true)
  })

  test('chooses a mask from the standard eight', () => {
    for (const text of ['riela', 'note', 'https://127.0.0.1:19091/x', 'a'.repeat(200)]) {
      const matrix = encodeQRCode(text)
      expect(matrix.mask).toBeGreaterThanOrEqual(0)
      expect(matrix.mask).toBeLessThan(8)
    }
  })

  test('rejects text that no version can hold', () => {
    expect(() => encodeQRCode('x'.repeat(3000))).toThrow(QRCodeError)
  })
})

describe('QR SVG runs', () => {
  test('reconstructs the matrix and offsets every run by the quiet zone', () => {
    const matrix = encodeQRCode('https://127.0.0.1:19091/note-api/register?code=ABC123')
    const runs = darkModuleRuns(matrix)
    const rebuilt = new Uint8Array(matrix.size * matrix.size)
    for (const run of runs) {
      expect(run.width).toBeGreaterThan(0)
      expect(run.x).toBeGreaterThanOrEqual(QUIET_ZONE)
      expect(run.y).toBeGreaterThanOrEqual(QUIET_ZONE)
      expect(run.x - QUIET_ZONE + run.width).toBeLessThanOrEqual(matrix.size)
      for (let offset = 0; offset < run.width; offset++) {
        rebuilt[(run.y - QUIET_ZONE) * matrix.size + (run.x - QUIET_ZONE + offset)] = 1
      }
    }
    expect(Array.from(rebuilt)).toEqual(Array.from(matrix.modules))
  })

  test('merges adjacent dark modules so runs are fewer than dark modules', () => {
    const matrix = encodeQRCode('https://127.0.0.1:19091/note-api/register?code=ABC123')
    const darkCount = matrix.modules.reduce((total, value) => total + value, 0)
    expect(darkModuleRuns(matrix).length).toBeLessThan(darkCount)
  })
})
