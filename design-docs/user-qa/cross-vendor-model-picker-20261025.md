# Cross-vendor model selection, 2026-10-25

The composer has one model combobox spanning enabled Claude, Gemini, and OpenAI
credential routes. Typing filters anywhere in the vendor label or model ID,
without case sensitivity. Choosing an option updates its model and provider
atomically. Subscription and API routes have distinct labels because they use
different credentials even when they expose the same model name.

Current IDs were checked against the official vendor catalogs:

- [OpenAI models](https://developers.openai.com/api/docs/models): GPT-6.1 Sol,
  GPT-6 Astra, and GPT-6 Luna.
- [Claude models](https://platform.claude.com/docs/en/models/overview): Claude
  Opus 5.5, Sonnet 5.5, Haiku 5.5, and Fable 5.1.
- [Gemini models](https://ai.google.dev/gemini-api/docs/models): Gemini 4 Argon,
  Gemini 3.8 Flash, and Gemini 3.5 Flash-Lite for the respective text tiers.

`gpt-5.6-luna` is removed from active defaults and migrated to `gpt-6.1-sol`.
The gateway resolves obsolete IDs from these model families to the current
vendor default; custom model IDs remain intact. Historical conversation records
and historical documentation are not rewritten.

Cross-vendor server credential use is explicit: `ai.agent.allowedProviders`
opts in individual gateway vendors, and chat routes use `server:<vendor>`.
The desktop local default enables Codex, Claude Code, OpenAI, and Gemini. A
server configuration without this opt-in retains its existing provider policy.
Switching vendors clears a credential-environment override belonging to the
previous vendor. Personal credentials remain scoped to their owner and keep
separate routes from server credentials.

The isolated test configuration at port 8790 was updated to current OpenAI
defaults. Readiness checks found Codex and Claude Code executables available;
OpenAI API and Gemini credentials were unavailable in the current process
environment. Choosing a model does not create credentials or guarantee that an
account has access to it. Gemini calls require its configured credential.
