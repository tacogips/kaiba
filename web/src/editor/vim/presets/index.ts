import defaultDocument from './default.json';
import miseDarwinDocument from './mise-darwin.json';

export type KeymapPresetId = 'default' | 'mise-darwin';
export interface KeymapPreset { id: KeymapPresetId; label: string; text: string }

export const KEYMAP_PRESETS: readonly KeymapPreset[] = [
  { id: 'default', label: 'Default', text: JSON.stringify(defaultDocument, null, 2) },
  { id: 'mise-darwin', label: 'mise-darwin', text: JSON.stringify(miseDarwinDocument, null, 2) },
];
