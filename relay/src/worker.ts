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
  RL_TRANSCRIBE: RateLimiter;
  RL_CHAT: RateLimiter;
  // Secrets — set with `wrangler secret put OPENAI_API_KEY` etc.
  OPENAI_API_KEY?: string;
  // Alibaba DashScope key for the Qwen realtime ASR proxy (中文 / 中英混说).
  // set with `wrangler secret put DASHSCOPE_API_KEY`.
  DASHSCOPE_API_KEY?: string;
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

    // Qwen realtime ASR. iOS/macOS opens a WebSocket here; the Worker bridges it
    // to Alibaba DashScope's OpenAI-Realtime-compatible endpoint, injecting the
    // DASHSCOPE_API_KEY server-side so the client stays zero-config and the key
    // is never shipped. Frames pass through verbatim — the client speaks the
    // DashScope dialect directly. Best-in-class 中文 + 中英混说 accuracy.
    if (url.pathname === "/v1/asr/qwen/socket") {
      const blocked = await rl(env.RL_MINT, req, "qwen-ws");
      if (blocked) return blocked;
      return proxyQwenRealtime(req, env);
    }

    // Qwen batch transcription — a full recorded clip → DashScope's multimodal
    // ASR (`qwen3-asr-flash`). Backs the Qwen engine's right-swipe re-transcription
    // and realtime-empty fallback so switching to Qwen is end-to-end Qwen (never
    // gpt-4o-transcribe). JSON body `{ audio: <base64 wav>, language?, corpus? }`;
    // key injected server-side; response normalized to `{ text }`.
    if (url.pathname === "/v1/asr/qwen/transcribe" && req.method === "POST") {
      const blocked = await rl(env.RL_TRANSCRIBE, req, "qwen-transcribe");
      if (blocked) return blocked;
      return proxyQwenTranscribe(req, env);
    }

    // Batch (non-realtime) transcription. iOS POSTs the full recorded utterance
    // as WAV bytes with NO key; the real OPENAI_API_KEY is injected server-side
    // and the model is forced. Higher accuracy than the streaming model — backs
    // the right-swipe "transcribe → preview → edit → send" flow.
    if (url.pathname === "/v1/audio/transcriptions" && req.method === "POST") {
      const blocked = await rl(env.RL_TRANSCRIBE, req, "transcribe");
      if (blocked) return blocked;
      return proxyTranscribe(req, env);
    }

    // Voice → shell command. iOS/macOS POSTs an OpenAI chat-completions body with
    // NO key; the real OPENAI_API_KEY is injected server-side and the model is
    // forced to a cheap, token-capped one so the shared key can't be run up.
    // Backs the left/right-swipe NL→shell feature zero-config (BYOK still routes
    // directly to OpenAI, never here).
    if (url.pathname === "/v1/chat/completions" && req.method === "POST") {
      const blocked = await rl(env.RL_CHAT, req, "chat");
      if (blocked) return blocked;
      return proxyChat(req, env);
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

// proxyTranscribe forwards a complete audio clip to OpenAI's batch
// transcription endpoint with the server-side key. Model is FORCED (caller
// can't pick), payload size is capped, and RL_TRANSCRIBE bounds volume per IP.
// The client sends raw WAV bytes in the body; we wrap them in the multipart
// form OpenAI expects. Phase 2 can require the pairing Ed25519 signature.
async function proxyTranscribe(req: Request, env: Env): Promise<Response> {
  if (!env.OPENAI_API_KEY) {
    return json({ error: "OPENAI_API_KEY not configured" }, 500);
  }

  const audio = await req.arrayBuffer();
  if (audio.byteLength === 0) return json({ error: "empty audio" }, 400);
  if (audio.byteLength > 10_000_000) return json({ error: "audio too large" }, 413);

  const language = new URL(req.url).searchParams.get("language") ?? "";

  const form = new FormData();
  form.append("file", new Blob([audio], { type: "audio/wav" }), "audio.wav");
  form.append("model", "gpt-4o-transcribe"); // forced — the better non-realtime model
  form.append("response_format", "json");
  if (language) form.append("language", language);

  const openaiResp = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}` },
    body: form,
  });

  // Pass OpenAI's JSON straight through — the client reads `{ text }`.
  const text = await openaiResp.text();
  return new Response(text, {
    status: openaiResp.ok ? 200 : 502,
    headers: { "content-type": "application/json" },
  });
}

// proxyChat backs the zero-config voice→shell feature. The client sends a normal
// OpenAI chat-completions body but no key; we inject OPENAI_API_KEY and pin the
// model + cap max_tokens server-side so a leaked/abused client can't pick an
// expensive model or run up huge completions on the shared key. Only `messages`
// (and an optional small temperature) are honored from the client.
async function proxyChat(req: Request, env: Env): Promise<Response> {
  if (!env.OPENAI_API_KEY) {
    return json({ error: "OPENAI_API_KEY not configured" }, 500);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  const messages = body?.messages;
  if (!Array.isArray(messages) || messages.length === 0) {
    return json({ error: "messages required" }, 400);
  }
  // Guard against a runaway payload padding the shared key's bill.
  if (JSON.stringify(messages).length > 20_000) {
    return json({ error: "messages too large" }, 413);
  }

  const temperature = typeof body.temperature === "number"
    ? Math.max(0, Math.min(body.temperature, 1))
    : 0.2;

  const upstream = {
    model: "gpt-4o-mini",           // forced — cheap, plenty for one shell line
    messages,
    temperature,
    max_tokens: 256,                // one command, never a paragraph
  };

  const openaiResp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(upstream),
  });

  // Pass OpenAI's JSON straight through — the client reads choices[0].message.content.
  const text = await openaiResp.text();
  return new Response(text, {
    status: openaiResp.ok ? 200 : 502,
    headers: { "content-type": "application/json" },
  });
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// proxyQwenRealtime bridges the client WebSocket to DashScope's realtime ASR
// endpoint (`qwen3-asr-flash-realtime`), which speaks the OpenAI-Realtime wire
// protocol. The Worker holds the DashScope key and adds it to the upstream
// upgrade, so the client connects with no credentials and the key never leaves
// the server. Frames are relayed byte-for-byte in both directions — no protocol
// translation — so the client drives the session (session.update, append,
// commit) directly. Abuse is bounded by RL_MINT (per-IP) upstream.
async function proxyQwenRealtime(req: Request, env: Env): Promise<Response> {
  if (!env.DASHSCOPE_API_KEY) {
    return json({ error: "DASHSCOPE_API_KEY not configured" }, 500);
  }
  if (req.headers.get("upgrade") !== "websocket") {
    return json({ error: "expected websocket upgrade" }, 426);
  }

  // Model is server-pinned but overridable via ?model= for future variants.
  const model = new URL(req.url).searchParams.get("model") || "qwen3-asr-flash-realtime";
  const upstreamURL =
    `https://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=${encodeURIComponent(model)}`;

  let upstreamResp: Response;
  try {
    upstreamResp = await fetch(upstreamURL, {
      headers: {
        Upgrade: "websocket",
        Authorization: `Bearer ${env.DASHSCOPE_API_KEY}`,
        "OpenAI-Beta": "realtime=v1",
      },
    });
  } catch (e) {
    return json({ error: "dashscope connect failed", detail: String(e) }, 502);
  }

  const upstream = upstreamResp.webSocket;
  if (!upstream) {
    const detail = (await upstreamResp.text().catch(() => "")).slice(0, 200);
    return json({ error: "dashscope did not upgrade", status: upstreamResp.status, detail }, 502);
  }
  upstream.accept();

  const [client, server] = Object.values(new WebSocketPair());
  server.accept();

  // Pump both directions. Reserved close codes (1005/1006) can't be forwarded
  // to close(), so we close without args to avoid a RangeError tearing down the
  // bridge — the peer still sees the socket drop.
  server.addEventListener("message", (e) => { try { upstream.send(e.data); } catch {} });
  upstream.addEventListener("message", (e) => { try { server.send(e.data); } catch {} });
  server.addEventListener("close", () => { try { upstream.close(); } catch {} });
  upstream.addEventListener("close", () => { try { server.close(); } catch {} });
  server.addEventListener("error", () => { try { upstream.close(); } catch {} });
  upstream.addEventListener("error", () => { try { server.close(); } catch {} });

  return new Response(null, { status: 101, webSocket: client });
}

// proxyQwenTranscribe transcribes a complete recorded clip with DashScope's
// multimodal ASR (`qwen3-asr-flash`) — the batch analog of the realtime proxy.
// The `system` message text is the context-biasing corpus (same entity-biasing
// as the realtime `corpus.text`). Key is injected server-side; the DashScope
// response is normalized to `{ text }` so the client reads it like the OpenAI
// batch route.
async function proxyQwenTranscribe(req: Request, env: Env): Promise<Response> {
  if (!env.DASHSCOPE_API_KEY) {
    return json({ error: "DASHSCOPE_API_KEY not configured" }, 500);
  }
  let body: { audio?: string; language?: string; corpus?: string };
  try {
    body = (await req.json()) as typeof body;
  } catch {
    return json({ error: "invalid json body" }, 400);
  }
  const audio = body.audio ?? "";
  if (!audio) return json({ error: "missing audio" }, 400);
  if (audio.length > 14_000_000) return json({ error: "audio too large" }, 413);

  const dataURI = audio.startsWith("data:") ? audio : `data:audio/wav;base64,${audio}`;
  const asrOptions: Record<string, unknown> = { enable_lid: true, enable_itn: false };
  if (body.language) asrOptions.language = body.language;

  const dsResp = await fetch(
    "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.DASHSCOPE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "qwen3-asr-flash",
        input: {
          messages: [
            { role: "system", content: [{ text: body.corpus ?? "" }] },
            { role: "user", content: [{ audio: dataURI }] },
          ],
        },
        parameters: { asr_options: asrOptions },
      }),
    },
  );

  if (!dsResp.ok) {
    const detail = (await dsResp.text().catch(() => "")).slice(0, 200);
    return json({ error: `dashscope ${dsResp.status}`, detail }, 502);
  }
  const data = (await dsResp.json()) as {
    output?: { choices?: Array<{ message?: { content?: Array<{ text?: string }> } }> };
  };
  const text = data.output?.choices?.[0]?.message?.content?.[0]?.text ?? "";
  return json({ text }, 200);
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

  // Client may hint model/language; default to gpt-realtime-whisper (the
  // canonical realtime transcription model). The client sends its own model
  // (with its own fallback chain), so this default only applies to empty bodies.
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
