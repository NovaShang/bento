// bento-relay Worker
//
// HTTP/WS entrypoint. Routes daemon and iOS sockets into the right Durable
// Object instance (`DaemonDO`), which owns all per-daemon state. The Worker
// itself is stateless and never sees decrypted SSH frames — those are
// end-to-end between the daemon and the iOS client.
//
// Routes:
//   POST /v1/daemon/register          → assign daemon_id (TODO: OIDC-gate)
//   GET  /v1/daemon/socket?...        → WSS, daemon side of the bridge
//   POST /v1/pair                     → iOS submits 6-digit code + pubkey
//   GET  /v1/tunnel?daemon_id=...     → WSS, iOS side of the bridge
//
// All paths under /v1/* with a daemon_id query param are forwarded to the
// matching DaemonDO instance.

import { DaemonDO } from "./daemon-do";

export { DaemonDO };

export interface Env {
  DAEMON_DO: DurableObjectNamespace;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

    // Public health check, no DO involved.
    if (url.pathname === "/healthz") {
      return new Response("ok\n", { status: 200 });
    }

    if (url.pathname.startsWith("/v1/")) {
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

// pickDaemonId resolves which DO instance to route to.
//
// - /v1/daemon/register: the daemon hasn't been assigned an id yet, so we
//   derive a candidate from a header it provides (a fresh client-side UUID).
//   The DO confirms or replaces it. TODO: tighten with OIDC.
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
