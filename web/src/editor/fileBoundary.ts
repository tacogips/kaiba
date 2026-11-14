/** Source replacement starts a new file's edit history, even for equal text. */
export function isFileBoundary(userEvent: string | null): boolean {
  return userEvent === 'input.replace.document' || userEvent === 'input.load.document';
}
