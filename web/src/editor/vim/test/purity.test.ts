
import { describe, expect, it } from 'vitest';

interface DirEntry { name: string; isDirectory(): boolean; isFile(): boolean }
interface NodeFs { readdirSync(path: string, options: { withFileTypes: true }): DirEntry[]; readFileSync(path: string, encoding: 'utf8'): string }
interface NodeProcess { cwd(): string }
const processApi = (globalThis as unknown as { process: NodeProcess }).process;

function withoutComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\s)\/\/.*$/gm, '');
}

describe('Vim core purity', () => {
  it('keeps Vim source DOM-free and independent of CodeMirror view', async () => {
    const spec: string = 'node:fs';
    const fs = await import(/* @vite-ignore */ spec) as NodeFs;
    const root = `${processApi.cwd()}/src/editor/vim`;
    const files: string[] = [];
    const visit = (directory: string): void => {
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const path = `${directory}/${entry.name}`;
        if (entry.isDirectory()) { if (entry.name !== 'test') visit(path); }
        else if (entry.isFile() && entry.name.endsWith('.ts')) files.push(path);
      }
    };
    visit(root);
    expect(files.length).toBeGreaterThanOrEqual(3);
    const violations: string[] = [];
    for (const file of files) {
      const source = withoutComments(fs.readFileSync(file, 'utf8'));
      if (/\b(?:document|window|navigator|localStorage|HTMLElement)\b/.test(source)) violations.push(`${file}: DOM global`);
      if (/\b(?:setTimeout|clearTimeout|setInterval|clearInterval)\b/.test(source)) violations.push(`${file}: timer global`);
      if (/from\s+['"]@codemirror\/view['"]/.test(source)) violations.push(`${file}: @codemirror/view import`);
    }
    expect(violations, violations.join('\n')).toEqual([]);
  });
});
