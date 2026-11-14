/** Renders a stored ISO timestamp in the viewer's locale; a value that does
 * not parse is shown verbatim rather than as "Invalid Date". */
export function formatTimestamp(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime())
    ? value
    : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}
