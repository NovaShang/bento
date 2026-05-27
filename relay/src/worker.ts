// bento-relay Worker
//
// HTTP/WS entrypoint. Routes daemon and iOS sockets into the right Durable
// Object instance (`DaemonDO`), which owns all per-daemon state. The Worker
// itself is stateless and never sees decrypted SSH frames — those are
// end-to-end between the daemon and the iOS client.
//
// Routes:
//   POST /v1/daemon/register          → materialize DO + echo daemon_id
//   GET  /v1/daemon/socket?...        → WSS, daemon side of the bridge
//                                       (Ed25519 host-key challenge required)
//   POST /v1/pair                     → iOS submits 6-digit code + pubkey
//   GET  /v1/tunnel?daemon_id=...     → WSS, iOS side of the bridge
//
// Identity auth lives on /v1/daemon/socket (TOFU-pinned host key). /register
// is a routing convenience; abuse is bounded by the per-IP rate limit.
//
// All paths under /v1/* with a daemon_id query param are forwarded to the
// matching DaemonDO instance.

import { DaemonDO } from "./daemon-do";

export { DaemonDO };

// RateLimiter is the typed surface of the CF rate-limit binding.
interface RateLimiter {
  limit(opts: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  DAEMON_DO: DurableObjectNamespace;
  RL_REGISTER: RateLimiter;
  RL_PAIR: RateLimiter;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

    // Public health check, no DO involved.
    if (url.pathname === "/healthz") {
      return new Response("ok\n", { status: 200 });
    }

    if (url.pathname.startsWith("/v1/")) {
      // IP-scoped rate limits on the abuse-prone endpoints. We rate-limit
      // BEFORE routing to the DO so we don't even spin one up on flood.
      if (url.pathname === "/v1/daemon/register") {
        const blocked = await rl(env.RL_REGISTER, req, "register");
        if (blocked) return blocked;
      } else if (url.pathname === "/v1/pair" && req.method === "POST") {
        const blocked = await rl(env.RL_PAIR, req, "pair");
        if (blocked) return blocked;
      }

      const daemonId = pickDaemonId(url, req);
      if (!daemonId) {
        return json({ error: "missing daemon_id" }, 400);
      }
      const id = env.DAEMON_DO.idFromName(daemonId);
      const stub = env.DAEMON_DO.get(id);
      return stub.fetch(req);
    }

    return new Response("bento-relay\n", { status: 200 });
  },
};

// rl applies the binding to the connecting IP. In local dev there is no
// `cf-connecting-ip` header; the binding itself is a no-op there too so we
// just skip cleanly.
async function rl(binding: RateLimiter | undefined, req: Request, tag: string): Promise<Response | null> {
  if (!binding) return null;
  const ip = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for") ?? "local";
  const result = await binding.limit({ key: `${tag}:${ip}` });
  if (!result.success) {
    return json({ error: "rate limited" }, 429);
  }
  return null;
}

// pickDaemonId resolves which DO instance to route to.
//
// - /v1/daemon/register: daemon supplies its id via `x-bento-daemon-id`.
//   The DO is materialized but unauthenticated until the WSS upgrade.
// - All other routes: must pass ?daemon_id=... explicitly.
function pickDaemonId(url: URL, req: Request): string | null {
  if (url.pathname === "/v1/daemon/register") {
    return req.headers.get("x-bento-daemon-id");
  }
  return url.searchParams.get("daemon_id");
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
