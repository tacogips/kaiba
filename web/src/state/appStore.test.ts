import { describe, expect, test } from 'bun:test'
import { NoteTransportError } from '../notes/client'
import { isUnauthorized } from './appStore'

// Only a transport-level 401 puts the shell into its unauthenticated state.
// Everything else keeps reporting through the error banner, so a flaky network
// or a schema mismatch never looks like a sign-out.

describe('unauthenticated classification', () => {
  test('accepts a transport 401', () => {
    expect(isUnauthorized(new NoteTransportError('note API requires a bearer token', 'http', 401))).toBe(true)
  })

  test('rejects other HTTP failures', () => {
    expect(isUnauthorized(new NoteTransportError('server error', 'http', 500))).toBe(false)
    expect(isUnauthorized(new NoteTransportError('not found', 'http', 404))).toBe(false)
  })

  test('rejects network, GraphQL and result failures', () => {
    expect(isUnauthorized(new NoteTransportError('offline', 'network'))).toBe(false)
    expect(isUnauthorized(new NoteTransportError('schema mismatch', 'graphql'))).toBe(false)
    expect(isUnauthorized(new NoteTransportError('rejected', 'result'))).toBe(false)
  })

  test('rejects values that are not transport errors', () => {
    expect(isUnauthorized(new Error('401'))).toBe(false)
    expect(isUnauthorized('401')).toBe(false)
    expect(isUnauthorized(undefined)).toBe(false)
  })
})
