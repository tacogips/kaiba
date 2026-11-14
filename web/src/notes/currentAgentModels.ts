/** Official vendor catalogs checked on 2026-10-25; account access is checked by the server/provider. */
export const currentAgentModels = {
  openai: ['gpt-6.1-sol', 'gpt-6-astra', 'gpt-6-luna'],
  anthropic: ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-1'],
  gemini: ['gemini-4-argon', 'gemini-3.8-flash', 'gemini-3.5-flash-lite'],
} as const

export function isCurrentAgentModel(model: string): boolean {
  const known = Object.values(currentAgentModels).flat() as readonly string[]
  return !/^(gpt-|claude-|gemini-)/.test(model) || known.includes(model)
}
