import type { Register } from './types';
import { textToTokens } from './record';

export function isRegisterName(ch: string): boolean {
  return /^[a-zA-Z0-9_+*"]$/.test(ch);
}

export class RegisterStore {
  private readonly values = new Map<string, Register>();
  private unnamed: Register | null = null;
  private mirror: Register | null = null;

  read(name: string): Register | null {
    if (name === '"') return this.unnamed;
    if (name === '_') return null;
    if (name === '+' || name === '*') return this.mirror;
    if (name === '0') return this.values.get('0') ?? null;
    return this.values.get(name.toLowerCase()) ?? null;
  }

  write(name: string | null, value: Register, kind: 'yank' | 'delete'): void {
    if (name === '_') return;
    if (name === null || name === '"') {
      this.unnamed = value;
      if (kind === 'yank') this.values.set('0', value);
      return;
    }
    if (name === '0') {
      this.values.set('0', value);
      this.unnamed = value;
      return;
    }
    if (/^[a-z]$/.test(name)) {
      this.values.set(name, value);
      this.unnamed = value;
      return;
    }
    if (/^[A-Z]$/.test(name)) {
      const prior = this.values.get(name.toLowerCase());
      const tokens = prior && (prior.tokens || value.tokens)
        ? [...(prior.tokens ?? textToTokens(prior.text)), ...(value.tokens ?? textToTokens(value.text))]
        : undefined;
      const appended: Register = prior
        ? { text: prior.linewise || value.linewise ? [prior.text, value.text].join('\n') : prior.text + value.text, linewise: prior.linewise || value.linewise, ...(tokens ? { tokens } : {}) }
        : value;
      this.values.set(name.toLowerCase(), appended);
      this.unnamed = appended;
      return;
    }
    if (name === '+' || name === '*') {
      this.mirror = value;
      this.unnamed = value;
    }
  }

  isClipboard(name: string): boolean {
    return name === '+' || name === '*';
  }

  setMirror(text: string, linewise: boolean): void {
    this.mirror = { text, linewise };
  }
}
