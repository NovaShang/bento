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
//   POST /v1/asr/mint                 → mint OpenAI Realtime ephemeral token
//                                       for the iOS client (gpt-realtime-whisper)
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
  RL_MINT: RateLimiter;
  // Secrets — set with `wrangler secret put OPENAI_API_KEY` etc.
  OPENAI_API_KEY?: string;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

    // Public health check, no DO involved.
    if (url.pathname === "/healthz") {
      return new Response("ok\n", { status: 200 });
    }

    // ASR token mint. Independent of the DO bridge — runs in the Worker.
    // iOS posts here to get a short-lived OpenAI Realtime client_secret,
    // then opens a WebSocket directly to api.openai.com using that token.
    // The real OPENAI_API_KEY only lives as a Wrangler secret server-side.
    if (url.pathname === "/v1/asr/mint" && req.method === "POST") {
      const blocked = await rl(env.RL_MINT, req, "mint");
      if (blocked) return blocked;
      return mintASRToken(req, env);
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

// mintASRToken proxies to OpenAI's transcription_sessions endpoint to mint
// a ~1-minute ephemeral client_secret. The endpoint is unauthenticated so
// the iOS app works out of the box; abuse is bounded by RL_MINT (per-IP
// per-minute) + the ~1-minute token TTL. Phase 2 can sign mint requests
// with the per-device Ed25519 key established at pairing.
async function mintASRToken(req: Request, env: Env): Promise<Response> {
  if (!env.OPENAI_API_KEY) {
    return json({ error: "OPENAI_API_KEY not configured" }, 500);
  }

  // Client may hint model/language; default to gpt-realtime-whisper.
  let clientBody: { model?: string; language?: string } = {};
  try {
    clientBody = (await req.json()) as typeof clientBody;
  } catch {
    // empty body is fine
  }
  const model = clientBody.model || "gpt-realtime-whisper";

  // GA shape (POST /v1/realtime/client_secrets). The legacy
  // /transcription_sessions endpoint was retired with the GA release.
  const transcription: Record<string, string> = { model };
  if (clientBody.language) transcription.language = clientBody.language;

  const openaiResp = await fetch(
    "https://api.openai.com/v1/realtime/client_secrets",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        session: {
          type: "transcription",
          audio: {
            input: {
              format: { type: "audio/pcm", rate: 24000 },
              transcription,
            },
          },
        },
      }),
    },
  );

  if (!openaiResp.ok) {
    const text = await openaiResp.text();
    return json({ error: `openai ${openaiResp.status}`, detail: text }, 502);
  }
  // GA returns a session object containing the ephemeral client_secret.
  // Accept both { value, expires_at } and { client_secret: { value } } —
  // OpenAI has shipped both shapes during the GA transition.
  const parsed = (await openaiResp.json()) as {
    value?: string;
    expires_at?: number;
    client_secret?: { value?: string; expires_at?: number };
  };
  const value = parsed.value ?? parsed.client_secret?.value;
  const expiresAt = parsed.expires_at ?? parsed.client_secret?.expires_at ?? 0;
  if (!value) {
    return json({ error: "missing client_secret in OpenAI response" }, 502);
  }
  return json({ value, expires_at: expiresAt }, 200);
}
