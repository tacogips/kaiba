import type { JSX } from 'solid-js'

export function PageHeader(props: { eyebrow: string; title: string; description: string; actions?: JSX.Element }) {
  return <div class="page-header"><div><span class="eyebrow">{props.eyebrow}</span><h1>{props.title}</h1><p>{props.description}</p></div><div class="header-actions">{props.actions}</div></div>
}

export function EmptyState(props: { title: string; detail: string }) {
  return <div class="empty-state"><span>◇</span><strong>{props.title}</strong><p>{props.detail}</p></div>
}

export function ErrorBanner(props: { message: string }) {
  return <div class="error-banner" role="alert">{props.message}</div>
}

export function LoadingState(props: { label: string }) {
  return <div class="loading-state" role="status"><span class="loader" aria-hidden="true" />{props.label}</div>
}

export function MutationMessage(props: { message: string; isError?: boolean; onRefresh?: () => void }) {
  return <div classList={{ 'mutation-message': true, error: props.isError }} role={props.isError ? 'alert' : 'status'} aria-live={props.isError ? 'assertive' : 'polite'}>
    <span>{props.message}</span>
    {props.onRefresh && <button class="secondary" type="button" onClick={props.onRefresh}>Refresh</button>}
  </div>
}
