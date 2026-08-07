import { For, Show, createMemo } from 'solid-js'

// Self-contained QR Code encoder: byte mode, error correction level M, versions 1-40.
// Implements ISO/IEC 18004 well enough for registration URLs; no runtime dependencies.

const MIN_VERSION = 1
const MAX_VERSION = 40
const QUIET_ZONE = 4
const FORMAT_BITS_M = 0
const PENALTY_SAME_RUN = 3
const PENALTY_BLOCK = 3
const PENALTY_FINDER_LIKE = 40
const PENALTY_IMBALANCE = 10

// Error correction codewords per block for level M, indexed by version - 1.
const ECC_CODEWORDS_PER_BLOCK = [
  10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
  26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
]

// Error correction block count for level M, indexed by version - 1.
const ECC_BLOCK_COUNT = [
  1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
  17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49,
]

export class QRCodeError extends Error {}

export interface QRCodeMatrix {
  version: number
  size: number
  mask: number
  /** Row-major dark-module flags, `size * size` entries. */
  modules: Uint8Array
}

function tableValue(values: readonly number[], index: number): number {
  const value = values[index]
  if (value === undefined) throw new QRCodeError(`QR table lookup out of range: ${index}`)
  return value
}

function byteAt(values: Uint8Array, index: number): number {
  const value = values[index]
  if (value === undefined) throw new QRCodeError(`QR byte lookup out of range: ${index}`)
  return value
}

/** Modules available for data and error correction codewords, before byte truncation. */
export function rawDataModuleCount(version: number): number {
  if (version < MIN_VERSION || version > MAX_VERSION) throw new QRCodeError(`Unsupported QR version ${version}`)
  let modules = (16 * version + 128) * version + 64
  if (version >= 2) {
    const alignmentCount = Math.floor(version / 7) + 2
    modules -= (25 * alignmentCount - 10) * alignmentCount - 55
    if (version >= 7) modules -= 36
  }
  return modules
}

export function totalCodewordCount(version: number): number {
  return Math.floor(rawDataModuleCount(version) / 8)
}

export function dataCodewordCount(version: number): number {
  return totalCodewordCount(version)
    - tableValue(ECC_CODEWORDS_PER_BLOCK, version - 1) * tableValue(ECC_BLOCK_COUNT, version - 1)
}

function characterCountBits(version: number): number {
  return version < 10 ? 8 : 16
}

export function smallestVersionFor(byteLength: number): number {
  for (let version = MIN_VERSION; version <= MAX_VERSION; version++) {
    const capacityBits = dataCodewordCount(version) * 8
    if (4 + characterCountBits(version) + byteLength * 8 <= capacityBits) return version
  }
  throw new QRCodeError('The text is too long to encode as a QR code.')
}

export function alignmentPatternPositions(version: number): number[] {
  if (version === 1) return []
  const count = Math.floor(version / 7) + 2
  const size = version * 4 + 17
  const step = version === 32 ? 26 : Math.ceil((size - 13) / (count * 2 - 2)) * 2
  const positions = [6]
  for (let position = size - 7; positions.length < count; position -= step) positions.splice(1, 0, position)
  return positions
}

function galoisMultiply(x: number, y: number): number {
  let product = 0
  for (let shift = 7; shift >= 0; shift--) {
    product = (product << 1) ^ ((product >>> 7) * 0x11d)
    product ^= ((y >>> shift) & 1) * x
  }
  return product & 0xff
}

function reedSolomonDivisor(degree: number): Uint8Array {
  const divisor = new Uint8Array(degree)
  divisor[degree - 1] = 1
  let root = 1
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < degree; j++) {
      divisor[j] = galoisMultiply(byteAt(divisor, j), root)
      if (j + 1 < degree) divisor[j] = byteAt(divisor, j) ^ byteAt(divisor, j + 1)
    }
    root = galoisMultiply(root, 0x02)
  }
  return divisor
}

function reedSolomonRemainder(data: Uint8Array, divisor: Uint8Array): Uint8Array {
  const remainder = new Uint8Array(divisor.length)
  for (const value of data) {
    const factor = value ^ byteAt(remainder, 0)
    remainder.copyWithin(0, 1)
    remainder[remainder.length - 1] = 0
    for (let i = 0; i < remainder.length; i++) {
      remainder[i] = byteAt(remainder, i) ^ galoisMultiply(byteAt(divisor, i), factor)
    }
  }
  return remainder
}

function dataCodewords(text: string, version: number): Uint8Array {
  const payload = new TextEncoder().encode(text)
  const capacityBits = dataCodewordCount(version) * 8
  const bits: number[] = []
  const appendBits = (value: number, length: number) => {
    for (let shift = length - 1; shift >= 0; shift--) bits.push((value >>> shift) & 1)
  }
  appendBits(0b0100, 4)
  appendBits(payload.length, characterCountBits(version))
  for (const value of payload) appendBits(value, 8)
  if (bits.length > capacityBits) throw new QRCodeError('The text is too long to encode as a QR code.')

  appendBits(0, Math.min(4, capacityBits - bits.length))
  appendBits(0, (8 - (bits.length % 8)) % 8)
  for (let pad = 0xec; bits.length < capacityBits; pad ^= 0xec ^ 0x11) appendBits(pad, 8)

  const codewords = new Uint8Array(bits.length / 8)
  bits.forEach((bit, index) => {
    codewords[index >>> 3] = byteAt(codewords, index >>> 3) | (bit << (7 - (index & 7)))
  })
  return codewords
}

function interleaveWithErrorCorrection(data: Uint8Array, version: number): Uint8Array {
  const blockCount = tableValue(ECC_BLOCK_COUNT, version - 1)
  const eccLength = tableValue(ECC_CODEWORDS_PER_BLOCK, version - 1)
  const rawCodewords = totalCodewordCount(version)
  const shortBlockCount = blockCount - (rawCodewords % blockCount)
  const shortBlockLength = Math.floor(rawCodewords / blockCount)
  const divisor = reedSolomonDivisor(eccLength)

  const blocks: number[][] = []
  let offset = 0
  for (let index = 0; index < blockCount; index++) {
    const length = shortBlockLength - eccLength + (index < shortBlockCount ? 0 : 1)
    const chunk = data.slice(offset, offset + length)
    offset += length
    const block = Array.from(chunk)
    if (index < shortBlockCount) block.push(0)
    blocks.push(block.concat(Array.from(reedSolomonRemainder(chunk, divisor))))
  }

  const result: number[] = []
  const blockLength = shortBlockLength + 1
  for (let position = 0; position < blockLength; position++) {
    blocks.forEach((block, blockIndex) => {
      if (position === shortBlockLength - eccLength && blockIndex < shortBlockCount) return
      const value = block[position]
      if (value !== undefined) result.push(value)
    })
  }
  return Uint8Array.from(result)
}

function maskBit(mask: number, x: number, y: number): boolean {
  switch (mask) {
    case 0: return (x + y) % 2 === 0
    case 1: return y % 2 === 0
    case 2: return x % 3 === 0
    case 3: return (x + y) % 3 === 0
    case 4: return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0
    case 5: return ((x * y) % 2) + ((x * y) % 3) === 0
    case 6: return (((x * y) % 2) + ((x * y) % 3)) % 2 === 0
    case 7: return (((x + y) % 2) + ((x * y) % 3)) % 2 === 0
    default: throw new QRCodeError(`Unsupported QR mask ${mask}`)
  }
}

class Canvas {
  readonly size: number
  readonly modules: Uint8Array
  private readonly reserved: Uint8Array

  constructor(readonly version: number) {
    this.size = version * 4 + 17
    this.modules = new Uint8Array(this.size * this.size)
    this.reserved = new Uint8Array(this.size * this.size)
  }

  private inside(x: number, y: number): boolean {
    return x >= 0 && x < this.size && y >= 0 && y < this.size
  }

  dark(x: number, y: number): boolean {
    return this.inside(x, y) && this.modules[y * this.size + x] === 1
  }

  isReserved(x: number, y: number): boolean {
    return this.reserved[y * this.size + x] === 1
  }

  setModule(x: number, y: number, dark: boolean): void {
    this.modules[y * this.size + x] = dark ? 1 : 0
  }

  private setFunctionModule(x: number, y: number, dark: boolean): void {
    if (!this.inside(x, y)) return
    this.setModule(x, y, dark)
    this.reserved[y * this.size + x] = 1
  }

  drawFunctionPatterns(): void {
    for (let index = 0; index < this.size; index++) {
      this.setFunctionModule(6, index, index % 2 === 0)
      this.setFunctionModule(index, 6, index % 2 === 0)
    }
    this.drawFinder(3, 3)
    this.drawFinder(this.size - 4, 3)
    this.drawFinder(3, this.size - 4)

    const positions = alignmentPatternPositions(this.version)
    const last = positions.length - 1
    positions.forEach((centerY, row) => {
      positions.forEach((centerX, column) => {
        const isFinderCorner = (row === 0 && column === 0)
          || (row === 0 && column === last)
          || (row === last && column === 0)
        if (!isFinderCorner) this.drawAlignment(centerX, centerY)
      })
    })

    this.drawFormatBits(0)
    this.drawVersionBits()
  }

  private drawFinder(centerX: number, centerY: number): void {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const distance = Math.max(Math.abs(dx), Math.abs(dy))
        this.setFunctionModule(centerX + dx, centerY + dy, distance !== 2 && distance !== 4)
      }
    }
  }

  private drawAlignment(centerX: number, centerY: number): void {
    for (let dy = -2; dy <= 2; dy++) {
      for (let dx = -2; dx <= 2; dx++) {
        this.setFunctionModule(centerX + dx, centerY + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1)
      }
    }
  }

  drawFormatBits(mask: number): void {
    const data = (FORMAT_BITS_M << 3) | mask
    let remainder = data
    for (let i = 0; i < 10; i++) remainder = (remainder << 1) ^ ((remainder >>> 9) * 0x537)
    const bits = (((data << 10) | remainder) ^ 0x5412) & 0x7fff
    const bit = (index: number) => ((bits >>> index) & 1) !== 0

    for (let i = 0; i <= 5; i++) this.setFunctionModule(8, i, bit(i))
    this.setFunctionModule(8, 7, bit(6))
    this.setFunctionModule(8, 8, bit(7))
    this.setFunctionModule(7, 8, bit(8))
    for (let i = 9; i < 15; i++) this.setFunctionModule(14 - i, 8, bit(i))

    for (let i = 0; i < 8; i++) this.setFunctionModule(this.size - 1 - i, 8, bit(i))
    for (let i = 8; i < 15; i++) this.setFunctionModule(8, this.size - 15 + i, bit(i))
    this.setFunctionModule(8, this.size - 8, true)
  }

  private drawVersionBits(): void {
    if (this.version < 7) return
    let remainder = this.version
    for (let i = 0; i < 12; i++) remainder = (remainder << 1) ^ ((remainder >>> 11) * 0x1f25)
    const bits = (this.version << 12) | remainder
    for (let i = 0; i < 18; i++) {
      const dark = ((bits >>> i) & 1) !== 0
      const far = this.size - 11 + (i % 3)
      const near = Math.floor(i / 3)
      this.setFunctionModule(far, near, dark)
      this.setFunctionModule(near, far, dark)
    }
  }

  drawCodewords(codewords: Uint8Array): void {
    let index = 0
    for (let right = this.size - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5
      for (let vertical = 0; vertical < this.size; vertical++) {
        for (let column = 0; column < 2; column++) {
          const x = right - column
          const upward = ((right + 1) & 2) === 0
          const y = upward ? this.size - 1 - vertical : vertical
          if (this.isReserved(x, y) || index >= codewords.length * 8) continue
          this.setModule(x, y, ((byteAt(codewords, index >>> 3) >>> (7 - (index & 7))) & 1) !== 0)
          index++
        }
      }
    }
  }

  applyMask(mask: number): void {
    for (let y = 0; y < this.size; y++) {
      for (let x = 0; x < this.size; x++) {
        if (this.isReserved(x, y)) continue
        if (maskBit(mask, x, y)) this.setModule(x, y, !this.dark(x, y))
      }
    }
  }

  penaltyScore(): number {
    let score = 0
    for (let y = 0; y < this.size; y++) {
      score += this.linePenalty((index) => this.dark(index, y))
    }
    for (let x = 0; x < this.size; x++) {
      score += this.linePenalty((index) => this.dark(x, index))
    }
    for (let y = 0; y < this.size - 1; y++) {
      for (let x = 0; x < this.size - 1; x++) {
        const color = this.dark(x, y)
        if (color === this.dark(x + 1, y) && color === this.dark(x, y + 1) && color === this.dark(x + 1, y + 1)) {
          score += PENALTY_BLOCK
        }
      }
    }
    let darkCount = 0
    for (const module of this.modules) darkCount += module
    const total = this.size * this.size
    score += (Math.ceil(Math.abs(darkCount * 20 - total * 10) / total) - 1) * PENALTY_IMBALANCE
    return score
  }

  private linePenalty(colorAt: (index: number) => boolean): number {
    let score = 0
    let runColor = false
    let runLength = 0
    const history = [0, 0, 0, 0, 0, 0, 0]
    for (let index = 0; index < this.size; index++) {
      if (colorAt(index) === runColor) {
        runLength++
        if (runLength === 5) score += PENALTY_SAME_RUN
        else if (runLength > 5) score++
        continue
      }
      this.pushRun(runLength, history)
      if (!runColor) score += countFinderLikePatterns(history) * PENALTY_FINDER_LIKE
      runColor = colorAt(index)
      runLength = 1
    }
    if (runColor) {
      this.pushRun(runLength, history)
      runLength = 0
    }
    this.pushRun(runLength + this.size, history)
    score += countFinderLikePatterns(history) * PENALTY_FINDER_LIKE
    return score
  }

  private pushRun(runLength: number, history: number[]): void {
    const padded = history[0] === 0 ? runLength + this.size : runLength
    history.pop()
    history.unshift(padded)
  }
}

function countFinderLikePatterns(history: number[]): number {
  const unit = tableValue(history, 1)
  const core = unit > 0
    && tableValue(history, 2) === unit
    && tableValue(history, 3) === unit * 3
    && tableValue(history, 4) === unit
    && tableValue(history, 5) === unit
  const leading = core && tableValue(history, 0) >= unit * 4 && tableValue(history, 6) >= unit ? 1 : 0
  const trailing = core && tableValue(history, 6) >= unit * 4 && tableValue(history, 0) >= unit ? 1 : 0
  return leading + trailing
}

/** Encodes `text` as a byte-mode, level-M QR code and returns its module matrix. */
export function encodeQRCode(text: string): QRCodeMatrix {
  const byteLength = new TextEncoder().encode(text).length
  const version = smallestVersionFor(byteLength)
  const canvas = new Canvas(version)
  canvas.drawFunctionPatterns()
  canvas.drawCodewords(interleaveWithErrorCorrection(dataCodewords(text, version), version))

  let bestMask = 0
  let bestScore = Number.POSITIVE_INFINITY
  for (let mask = 0; mask < 8; mask++) {
    canvas.applyMask(mask)
    canvas.drawFormatBits(mask)
    const score = canvas.penaltyScore()
    if (score < bestScore) {
      bestScore = score
      bestMask = mask
    }
    canvas.applyMask(mask)
  }
  canvas.applyMask(bestMask)
  canvas.drawFormatBits(bestMask)

  return { version, size: canvas.size, mask: bestMask, modules: canvas.modules }
}

export interface QRCodeRun {
  x: number
  y: number
  width: number
}

/** Merges each row's dark modules into horizontal runs so the SVG stays small. */
export function darkModuleRuns(matrix: QRCodeMatrix): QRCodeRun[] {
  const runs: QRCodeRun[] = []
  for (let y = 0; y < matrix.size; y++) {
    let start = -1
    for (let x = 0; x <= matrix.size; x++) {
      const dark = x < matrix.size && matrix.modules[y * matrix.size + x] === 1
      if (dark && start < 0) start = x
      if (!dark && start >= 0) {
        runs.push({ x: start + QUIET_ZONE, y: y + QUIET_ZONE, width: x - start })
        start = -1
      }
    }
  }
  return runs
}

export function QRCodeSVG(props: { text: string; size?: number }) {
  const encoded = createMemo(() => {
    try {
      return { matrix: encodeQRCode(props.text) }
    } catch (error) {
      return { failure: error instanceof Error ? error.message : String(error) }
    }
  })
  const extent = () => {
    const matrix = encoded().matrix
    return matrix ? matrix.size + QUIET_ZONE * 2 : 0
  }
  const pixels = () => props.size ?? 180

  return <Show when={encoded().matrix} fallback={<p class="qr-failure">{encoded().failure}</p>}>
    {(matrix) => <svg
      class="qr-code"
      role="img"
      aria-label="Registration QR code"
      width={pixels()}
      height={pixels()}
      viewBox={`0 0 ${extent()} ${extent()}`}
      shape-rendering="crispEdges"
    >
      <rect x="0" y="0" width={extent()} height={extent()} fill="#ffffff" />
      <For each={darkModuleRuns(matrix())}>
        {(run) => <rect x={run.x} y={run.y} width={run.width} height="1" fill="#000000" />}
      </For>
    </svg>}
  </Show>
}
