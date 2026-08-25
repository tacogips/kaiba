export type Env = {
  readonly DB: D1Database;
  readonly ASSETS: Fetcher;
  readonly WEB_ORIGIN?: string | undefined;
  readonly KAIBA_API_TOKEN?: string | undefined;
};
