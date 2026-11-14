import { describe, expect, test } from 'bun:test'
import { popReturn, pushReturn, returnStackLimit } from './returnStack'

describe('returnStack', () => {
  test('push and pop restore in reverse order', () => {
    let stack = pushReturn([], '#/note/a')
    stack = pushReturn(stack, '#/note/b')
    const first = popReturn(stack)
    expect(first.hash).toBe('#/note/b')
    const second = popReturn(first.stack)
    expect(second.hash).toBe('#/note/a')
    expect(popReturn(second.stack)).toEqual({ stack: [] })
  })

  test('does not stack the same hash twice in a row', () => {
    const stack = pushReturn(pushReturn([], '#/note/a'), '#/note/a')
    expect(stack).toEqual(['#/note/a'])
  })

  test('caps the stack at the limit, dropping the oldest entries', () => {
    let stack: string[] = []
    for (let index = 0; index < returnStackLimit + 10; index += 1) {
      stack = pushReturn(stack, `#/note/${index}`)
    }
    expect(stack).toHaveLength(returnStackLimit)
    expect(stack[0]).toBe('#/note/10')
    expect(stack[stack.length - 1]).toBe(`#/note/${returnStackLimit + 9}`)
  })
})
