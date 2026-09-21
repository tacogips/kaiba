import { type JSX } from 'solid-js'

const paths = {
  tree: 'M5 3v14h5 M5 7h5 M10 5h10v4H10z M10 15h10v4H10z',
  timeline: 'M5 3v18 M3 6h4 M3 12h4 M3 18h4 M11 6h10 M11 12h10 M11 18h10',
  keyboard: 'M2 5h20v14H2z M6 9h.01 M10 9h.01 M14 9h.01 M18 9h.01 M6 13h.01 M10 13h8',
  files: 'M3 4h7l2 2h9v14H3z M3 9h18',
  search: 'M16 16l5 5 M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  settings: 'M4 7h16 M4 17h16 M8 4v6 M16 14v6',
  refresh: 'M20 8a8 8 0 1 0 0 8 M20 3v5h-5',
  ai: 'M12 3l3 6 6 3-6 3-3 6-3-6-6-3 6-3z',
  tags: 'M3 3h8l10 10-8 8L3 11z M7 7h.01',
  add: 'M12 5v14 M5 12h14',
  save: 'M5 3h12l4 4v14H3V3z M7 3v6h10V3 M7 21v-8h10v8',
  close: 'M6 6l12 12 M6 18L18 6',
  edit: 'M4 16l-1 5 5-1L21 7l-4-4z M14 6l4 4',
  send: 'M12 20V4 M5 11l7-7 7 7',
  back: 'M20 12H4 M11 5l-7 7 7 7',
  copy: 'M8 8h13v13H8z M16 8V3H3v13h5',
  file: 'M5 3h9l5 5v13H5z M14 3v6h5 M8 13h8 M8 17h6',
  more: 'M5 12h.01 M12 12h.01 M19 12h.01',
  download: 'M12 3v12 M6 9l6 6 6-6 M4 16v5h16v-5',
  expand: 'M3 9V3h6 M15 3h6v6 M21 15v6h-6 M9 21H3v-6',
  links: 'M9 15l6-6 M8 17l-1 1a4 4 0 0 1-6-6l5-5a4 4 0 0 1 6 0 M16 7l1-1a4 4 0 0 1 6 6l-5 5a4 4 0 0 1-6 0',
} as const

export function WorkspaceIcon(props: { name: keyof typeof paths }): JSX.Element {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor"
    stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d={paths[props.name]} />
  </svg>
}
