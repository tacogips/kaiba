import { D1KaibaRepository } from "@kaiba/adapter";
import type { Env } from "./env";
import { createKaibaGraphQLServer } from "./server";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return json({ status: "ok", aiRuntime: false });
    }
    const origin = env.WEB_ORIGIN ?? "http://localhost:5173";
    if (request.method === "OPTIONS")
      return cors(new Response(null, { status: 204 }), origin);
    if (url.pathname !== "/graphql") return env.ASSETS.fetch(request);
    if (!(await isAuthorized(request, env.KAIBA_API_TOKEN))) {
      return cors(json({ error: "unauthorized" }, 401), origin);
    }
    const yoga = createKaibaGraphQLServer(new D1KaibaRepository(env.DB));
    return cors(await yoga.fetch(request), origin);
  },
};

async function isAuthorized(
  request: Request,
  expected?: string,
): Promise<boolean> {
  if (!expected) return true;
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return false;
  const presented = authorization.slice("Bearer ".length);
  const [expectedDigest, presentedDigest] = await Promise.all([
    digest(expected),
    digest(presented),
  ]);
  return expectedDigest.every(
    (value, index) => value === presentedDigest[index],
  );
}

async function digest(value: string): Promise<Uint8Array> {
  const bytes = new TextEncoder().encode(value);
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function cors(response: Response, origin: string): Response {
  const result = new Response(response.body, response);
  result.headers.set("access-control-allow-origin", origin);
  result.headers.set(
    "access-control-allow-headers",
    "authorization, content-type",
  );
  result.headers.set("access-control-allow-methods", "POST, OPTIONS");
  result.headers.set("vary", "Origin");
  return result;
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status });
}
