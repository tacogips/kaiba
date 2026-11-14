import { type JSX } from 'solid-js'

const paths = {
  files: 'M3 4h7l2 2h9v14H3z M3 9h18',
  search: 'M16 16l5 5 M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  settings: 'M4 7h16 M4 17h16 M8 4v6 M16 14v6',
  refresh: 'M20 8a8 8 0 1 0 0 8 M20 3v5h-5',
  ai: 'M12 3l3 6 6 3-6 3-3 6-3-6-6-3 6-3z',
  links: 'M9 15l6-6 M8 17l-1 1a4 4 0 0 1-6-6l5-5a4 4 0 0 1 6 0 M16 7l1-1a4 4 0 0 1 6 6l-5 5a4 4 0 0 1-6 0',
} as const

export function WorkspaceIcon(props: { name: keyof typeof paths }): JSX.Element {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor"
    stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d={paths[props.name]} />
  </svg>
}
