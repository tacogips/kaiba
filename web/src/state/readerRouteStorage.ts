import { formatRoute, homeRoute, parseRoute, rememberReaderRoute, type Route } from '../router'
import type { PaneStateStorage } from './paneState'

const key = 'kaiba.reader-route.v1'

/** Session-scoped so a Settings reload can still return to its source reader. */
export function readReaderRoute(storage?: PaneStateStorage): Route {
  try { return rememberReaderRoute(parseRoute(storage?.getItem(key) ?? '#/')) }
  catch { return homeRoute }
}

export function writeReaderRoute(route: Route, storage?: PaneStateStorage): void {
  try { storage?.setItem(key, formatRoute(rememberReaderRoute(route))) }
  catch { /* Storage-disabled clients still retain the route in memory. */ }
}

export function browserReaderRouteStorage(): PaneStateStorage | undefined {
  try { return typeof sessionStorage === 'undefined' ? undefined : sessionStorage }
  catch { return undefined }
}
