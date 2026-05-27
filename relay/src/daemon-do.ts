// DaemonDO — one instance per daemon_id.
//
// Holds:
//   - the daemon-side WSS (one at a time; new registration evicts the old)
//   - any active iOS-side WSS connections (bridged 1:1 to a daemon stream)
//   - the open pairing slot, if any (60s TTL)
//
// The DO does NOT inspect SSH bytes. It only frames a tiny envelope so the
// daemon can multiplex multiple iOS connections over the single daemon WSS.
//
// Wire framing (binary WebSocket messages, all big-endian):
//   1 byte: type (0x01=open, 0x02=data, 0x03=close, 0x10=control-json)
//   4 bytes: stream_id  (assigned by DO, 0 means "control plane")
//   N bytes: payload     (SSH bytes for data; JSON for control)
//
// Implemented: daemon socket, control ping/pong, stream multiplex, pairing
// slot, and the /v1/pair handler that awaits a daemon ack.

const TYPE_OPEN = 0x01;
const TYPE_DATA = 0x02;
const TYPE_CLOSE = 0x03;
const TYPE_CONTROL = 0x10;

interface Stream {
  id: number;
  ios: WebSocket;
}

interface PairingSlot {
  code: string;
  expiresAt: number; // epoch ms
}

interface PendingAttach {
  resolve: (body: unknown) => void;
  reject: (err: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}

export class DaemonDO {
  private state: DurableObjectState;
  private daemon: WebSocket | null = null;
  private streams = new Map<number, Stream>();
  private nextStreamId = 1;
  private pairing: PairingSlot | null = null;
  private pendingAttach = new Map<string, PendingAttach>();
  private nextAttachId = 1;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);

    switch (url.pathname) {
      case "/v1/daemon/register":
        return this.handleDaemonRegister(req);
      case "/v1/daemon/socket":
        return this.handleDaemonSocket(req);
      case "/v1/tunnel":
        return this.handleIOSSocket(req);
      case "/v1/pair":
        return this.handlePair(req);
      case "/v1/pair/open":
        return this.handlePairOpen(req);
      default:
        return json({ error: "not found" }, 404);
    }
  }

  // -------- daemon side --------

  private async handleDaemonRegister(req: Request): Promise<Response> {
    // TODO: verify a Nova Auth token and bind account_id. For now we just
    // echo back the id (the Worker derived it from the daemon's header).
    const daemonId = this.state.id.name ?? this.state.id.toString();
    return json({ daemon_id: daemonId });
  }

  private async handleDaemonSocket(req: Request): Promise<Response> {
    if (req.headers.get("upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();

    if (this.daemon) {
      // New registration evicts the old socket; daemons reconnect with
      // exponential backoff if the relay drops them.
      try {
        this.daemon.close(4000, "replaced by newer connection");
      } catch {}
      this.daemon = null;
      this.closeAllStreams("daemon replaced");
    }
    this.daemon = server;

    server.addEventListener("message", (ev) => this.onDaemonMessage(ev));
    server.addEventListener("close", () => {
      this.daemon = null;
      this.closeAllStreams("daemon disconnected");
    });
    server.addEventListener("error", () => {
      this.daemon = null;
      this.closeAllStreams("daemon error");
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  private onDaemonMessage(ev: MessageEvent) {
    const data = ev.data;
    if (!(data instanceof ArrayBuffer)) {
      // Text frames are reserved for control JSON; not currently used —
      // the daemon sends everything as binary so we have one parsing path.
      return;
    }
    const frame = parseFrame(data);
    if (!frame) return;

    if (frame.streamId === 0 && frame.type === TYPE_CONTROL) {
      this.handleDaemonControl(frame.payload);
      return;
    }
    const s = this.streams.get(frame.streamId);
    if (!s) return;

    if (frame.type === TYPE_DATA) {
      try {
        s.ios.send(frame.payload);
      } catch {
        this.closeStream(frame.streamId, "ios send failed");
      }
    } else if (frame.type === TYPE_CLOSE) {
      this.closeStream(frame.streamId, "daemon closed stream");
    }
  }

  private handleDaemonControl(payload: ArrayBuffer) {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(new TextDecoder().decode(payload));
    } catch {
      return;
    }
    const t = msg.type;
    if (t === "pair.open") {
      const ttl = clamp(Number(msg.ttl_sec ?? 60), 30, 300);
      const code = mintCode();
      this.pairing = { code, expiresAt: Date.now() + ttl * 1000 };
      this.sendDaemonControl({ type: "pair.opened", code, ttl_sec: ttl });
    } else if (t === "pair.cancel") {
      this.pairing = null;
    } else if (t === "pair.ack") {
      const reqID = String(msg.request_id ?? "");
      const pending = this.pendingAttach.get(reqID);
      if (!pending) return;
      this.pendingAttach.delete(reqID);
      clearTimeout(pending.timer);
      if (msg.status === "ok") {
        pending.resolve({
          status: "ok",
          device_id: msg.device_id,
          host_fingerprint: msg.host_fingerprint,
        });
      } else {
        pending.resolve({ status: "error", error: msg.error ?? "unknown" });
      }
    } else if (t === "ping") {
      this.sendDaemonControl({ type: "pong", t: Date.now() });
    }
  }

  private sendDaemonControl(obj: unknown) {
    if (!this.daemon) return;
    const payload = new TextEncoder().encode(JSON.stringify(obj));
    this.daemon.send(buildFrame(TYPE_CONTROL, 0, payload));
  }

  // -------- iOS side --------

  private async handleIOSSocket(req: Request): Promise<Response> {
    if (req.headers.get("upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    if (!this.daemon) {
      return new Response("daemon offline", { status: 503 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();

    const streamId = this.nextStreamId++;
    this.streams.set(streamId, { id: streamId, ios: server });

    // Tell the daemon to open a matching stream. The daemon's SSH server
    // authenticates the iOS device from its pubkey during the SSH handshake;
    // the relay never needs to know who the device is.
    this.sendDaemonFrame(TYPE_OPEN, streamId, new Uint8Array(0));

    server.addEventListener("message", (ev) => {
      if (ev.data instanceof ArrayBuffer) {
        this.sendDaemonFrame(TYPE_DATA, streamId, new Uint8Array(ev.data));
      }
    });
    server.addEventListener("close", () => this.closeStream(streamId, "ios closed"));
    server.addEventListener("error", () => this.closeStream(streamId, "ios error"));

    return new Response(null, { status: 101, webSocket: client });
  }

  // -------- pairing (HTTP) --------

  private async handlePairOpen(req: Request): Promise<Response> {
    // Caller is the daemon's local Mac App / CLI, proxied through the daemon's
    // existing WSS — but we also accept this as an HTTP fallback for tests.
    if (req.method !== "POST") return json({ error: "POST required" }, 405);
    if (!this.daemon) return json({ error: "daemon offline" }, 503);
    const code = mintCode();
    this.pairing = { code, expiresAt: Date.now() + 60_000 };
    return json({ code, ttl_sec: 60 });
  }

  private async handlePair(req: Request): Promise<Response> {
    if (req.method !== "POST") return json({ error: "POST required" }, 405);
    if (!this.pairing || Date.now() > this.pairing.expiresAt) {
      return json({ error: "no pairing window open" }, 400);
    }
    let body: { code?: string; device_pubkey?: string; device_label?: string };
    try {
      body = await req.json();
    } catch {
      return json({ error: "bad json" }, 400);
    }
    if (!body.code || body.code !== this.pairing.code) {
      return json({ error: "bad code" }, 401);
    }
    if (!body.device_pubkey) {
      return json({ error: "missing device_pubkey" }, 400);
    }
    if (!this.daemon) return json({ error: "daemon offline" }, 503);

    // Burn the pairing slot immediately so a stolen code can't be replayed
    // while we wait on the daemon.
    this.pairing = null;

    const reqID = `att-${this.nextAttachId++}`;
    const result = new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingAttach.delete(reqID);
        reject(new Error("daemon did not ack within 10s"));
      }, 10_000);
      this.pendingAttach.set(reqID, { resolve, reject, timer });
    });

    this.sendDaemonControl({
      type: "pair.attach",
      request_id: reqID,
      device_pubkey: body.device_pubkey,
      device_label: body.device_label ?? "",
    });

    try {
      const ack = (await result) as { status: string; [k: string]: unknown };
      const code = ack.status === "ok" ? 200 : 502;
      return json(ack, code);
    } catch (e) {
      return json({ status: "error", error: (e as Error).message }, 504);
    }
  }

  // -------- helpers --------

  private sendDaemonFrame(type: number, streamId: number, payload: Uint8Array) {
    if (!this.daemon) return;
    this.daemon.send(buildFrame(type, streamId, payload));
  }

  private closeStream(streamId: number, reason: string) {
    const s = this.streams.get(streamId);
    if (!s) return;
    this.streams.delete(streamId);
    try {
      s.ios.close(1000, reason);
    } catch {}
    this.sendDaemonFrame(TYPE_CLOSE, streamId, new Uint8Array(0));
  }

  private closeAllStreams(reason: string) {
    for (const id of this.streams.keys()) this.closeStream(id, reason);
  }
}

// ---- helpers ----

function buildFrame(type: number, streamId: number, payload: Uint8Array): ArrayBuffer {
  const buf = new Uint8Array(1 + 4 + payload.byteLength);
  buf[0] = type;
  new DataView(buf.buffer).setUint32(1, streamId, false);
  buf.set(payload, 5);
  return buf.buffer;
}

function parseFrame(buf: ArrayBuffer): { type: number; streamId: number; payload: ArrayBuffer } | null {
  if (buf.byteLength < 5) return null;
  const view = new DataView(buf);
  return {
    type: view.getUint8(0),
    streamId: view.getUint32(1, false),
    payload: buf.slice(5),
  };
}

function mintCode(): string {
  // 6 digits, leading zeros allowed.
  const n = Math.floor(Math.random() * 1_000_000);
  return n.toString().padStart(6, "0");
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, n));
}

function json(body: unknown, status: number = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
