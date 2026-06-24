// DaemonDO — one instance per daemon_id.
//
// Holds:
//   - the daemon-side WSS (one at a time; new registration evicts the old)
//   - any active iOS-side WSS connections (bridged 1:1 to a daemon stream)
//   - the open pairing slot, if any (60s TTL)
//   - brute-force counters for the 6-digit pairing code
//
// The DO does NOT inspect SSH bytes. It only frames a tiny envelope so the
// daemon can multiplex multiple iOS connections over the single daemon WSS.
//
// Wire framing (binary WebSocket messages, big-endian):
//
//   0       1     2                   6                     N
//   +-------+-----+-------------------+---------------------+
//   |version| type| stream_id(uint32) | payload             |
//   +-------+-----+-------------------+---------------------+
//
// Types: 0x01=open, 0x02=data, 0x03=close, 0x10=control-json.
// Version 0x01 — bump for any breaking change.
//
// Implemented: daemon socket, control ping/pong, stream multiplex, pairing
// slot with brute-force lockout, and a /v1/pair handler that awaits a
// daemon ack.
//
// Uses the WebSocket Hibernation API so a DO with idle long-lived
// connections can be evicted from memory between messages, with state
// reconstructed from durable storage + socket attachments.

const VERSION = 0x01;
const HEADER_LEN = 6;

const TYPE_OPEN = 0x01;
const TYPE_DATA = 0x02;
const TYPE_CLOSE = 0x03;
const TYPE_CONTROL = 0x10;

const ROLE_DAEMON = "daemon";
const ROLE_IOS = "ios";

const MAX_BAD_ATTEMPTS = 5;
const LOCKOUT_MS = 60_000;
const PAIR_ACK_TIMEOUT_MS = 10_000;

// Per-socket attachment stored via ws.serializeAttachment(). Survives
// hibernation; we use it to identify sockets after the DO restarts.
interface Attachment {
  role: "daemon" | "ios";
  streamId?: number; // iOS only
}

// Storage keys for state that must survive hibernation.
const K_PAIR = "pair";
const K_BAD_ATTEMPTS = "bad_attempts";
const K_LOCKED_UNTIL = "locked_until";
const K_NEXT_STREAM_ID = "next_stream_id";
const K_DAEMON_PUBKEY = "daemon_pubkey"; // raw 32-byte Ed25519, hex
const K_DEVICE_PREFIX = "device:"; // `device:<device_id>` → raw 32-byte Ed25519 pubkey, hex

// Max acceptable clock skew on the daemon's signed timestamp.
const CHALLENGE_MAX_SKEW_SEC = 30;

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

  // pendingAttach is only used while a /v1/pair HTTP request is in flight;
  // an HTTP request blocks hibernation, so we don't need to persist it.
  private pendingAttach = new Map<string, PendingAttach>();
  private nextAttachId = 1;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    switch (url.pathname) {
      case "/v1/daemon/register":
        return this.handleDaemonRegister();
      case "/v1/daemon/socket":
        return this.handleDaemonSocket(req);
      case "/v1/tunnel":
        return this.handleIOSSocket(req);
      case "/v1/pair":
        return this.handlePair(req);
      case "/v1/pair/open":
        return this.handlePairOpen();
      default:
        return json({ error: "not found" }, 404);
    }
  }

  // ============== daemon side ==============

  private handleDaemonRegister(): Response {
    // /register just materializes the DO and echoes the id back. Real
    // identity auth happens on the WSS upgrade via verifyDaemonChallenge,
    // where the daemon proves possession of its Ed25519 host key.
    const daemonId = this.state.id.name ?? this.state.id.toString();
    return json({ daemon_id: daemonId });
  }

  private async handleDaemonSocket(req: Request): Promise<Response> {
    if (req.headers.get("upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const authErr = await this.verifyDaemonChallenge(req);
    if (authErr) return new Response(authErr, { status: 401 });

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];

    // Evict any prior daemon socket. New registration wins; daemons reconnect
    // with backoff if they see themselves dropped.
    for (const existing of this.state.getWebSockets(ROLE_DAEMON)) {
      try {
        existing.close(4000, "replaced by newer connection");
      } catch {
        /* ignore */
      }
    }
    // Streams tied to the old daemon are now orphaned; close them so iOS
    // doesn't hang.
    this.closeAllStreams("daemon replaced");

    const attachment: Attachment = { role: "daemon" };
    server.serializeAttachment(attachment);
    this.state.acceptWebSocket(server, [ROLE_DAEMON]);

    return new Response(null, { status: 101, webSocket: client });
  }

  // verifyDaemonChallenge enforces TOFU-pinned Ed25519 host key auth on every
  // WSS connect: the URL must carry ts, pubkey, sig query params. The
  // signature must cover `bento-daemon-register:<daemonId>:<ts>`, ts must be
  // within CHALLENGE_MAX_SKEW_SEC, and pubkey must match whatever we pinned
  // on first contact.
  private async verifyDaemonChallenge(req: Request): Promise<string | null> {
    const url = new URL(req.url);
    // daemon_id is the friendly name the Worker used with idFromName(); both
    // sides MUST agree on the same string when constructing the signed
    // challenge. state.id.name is only set in some runtimes, so read the
    // query param directly.
    const daemonId = url.searchParams.get("daemon_id") ?? "";
    const ts = parseInt(url.searchParams.get("ts") ?? "", 10);
    const pubB64 = url.searchParams.get("pubkey") ?? "";
    const sigB64 = url.searchParams.get("sig") ?? "";
    if (!daemonId || !ts || !pubB64 || !sigB64) return "missing challenge params";

    const skew = Math.abs(Date.now() / 1000 - ts);
    if (skew > CHALLENGE_MAX_SKEW_SEC) return "challenge timestamp out of window";

    const pubkey = decodeB64Url(pubB64);
    const sig = decodeB64Url(sigB64);
    if (!pubkey || pubkey.length !== 32) return "bad pubkey";
    if (!sig || sig.length !== 64) return "bad signature";
    const pinned = (await this.state.storage.get(K_DAEMON_PUBKEY)) as string | undefined;
    if (pinned && pinned !== toHex(pubkey)) {
      return "pubkey mismatch (this daemon_id is bound to a different host key)";
    }

    const msg = new TextEncoder().encode(`bento-daemon-register:${daemonId}:${ts}`);
    let ok = false;
    try {
      const key = await crypto.subtle.importKey("raw", pubkey, { name: "Ed25519" }, false, ["verify"]);
      ok = await crypto.subtle.verify({ name: "Ed25519" }, key, sig, msg);
    } catch (e) {
      return `crypto.verify failed: ${(e as Error).message}`;
    }
    if (!ok) return "bad signature";

    if (!pinned) {
      // TOFU: pin this pubkey to the daemon_id on first valid connect.
      await this.state.storage.put(K_DAEMON_PUBKEY, toHex(pubkey));
    }
    return null;
  }

  // ============== iOS side ==============

  private async handleIOSSocket(req: Request): Promise<Response> {
    if (req.headers.get("upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    if (!this.getDaemon()) return new Response("daemon offline", { status: 503 });

    const authErr = await this.verifyDeviceChallenge(req);
    if (authErr) return new Response(authErr, { status: 401 });

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    const streamId = await this.allocateStreamId();
    const attachment: Attachment = { role: ROLE_IOS, streamId };
    server.serializeAttachment(attachment);
    this.state.acceptWebSocket(server, [ROLE_IOS, `stream:${streamId}`]);

    // Tell the daemon to open a matching stream. The SSH layer below will
    // authenticate the device a second time via authorized_keys, but doing
    // it here too lets us reject unauthenticated stream opens without
    // burning a daemon goroutine on every bogus request.
    this.sendDaemonFrame(TYPE_OPEN, streamId, new Uint8Array(0));

    return new Response(null, { status: 101, webSocket: client });
  }

  // verifyDeviceChallenge enforces device-key auth on every iOS tunnel
  // open: the URL must carry device_id, ts, pubkey, sig query params. The
  // signature must cover `bento-device-attach:<daemonId>:<deviceId>:<ts>`,
  // ts must be within CHALLENGE_MAX_SKEW_SEC, and pubkey must match the
  // device pubkey we pinned at pair time (or pin it now if pairing
  // happened before this auth was deployed).
  private async verifyDeviceChallenge(req: Request): Promise<string | null> {
    const url = new URL(req.url);
    const daemonId = url.searchParams.get("daemon_id") ?? "";
    const deviceId = url.searchParams.get("device_id") ?? "";
    const ts = parseInt(url.searchParams.get("ts") ?? "", 10);
    const pubB64 = url.searchParams.get("pubkey") ?? "";
    const sigB64 = url.searchParams.get("sig") ?? "";
    if (!daemonId || !deviceId || !ts || !pubB64 || !sigB64) {
      return "missing device challenge params";
    }

    const skew = Math.abs(Date.now() / 1000 - ts);
    if (skew > CHALLENGE_MAX_SKEW_SEC) return "device challenge timestamp out of window";

    const pubkey = decodeB64Url(pubB64);
    const sig = decodeB64Url(sigB64);
    if (!pubkey || pubkey.length !== 32) return "bad device pubkey";
    if (!sig || sig.length !== 64) return "bad device signature";

    const key = `${K_DEVICE_PREFIX}${deviceId}`;
    const pinned = (await this.state.storage.get(key)) as string | undefined;
    if (pinned && pinned !== toHex(pubkey)) {
      return "device pubkey mismatch (device_id is bound to a different key)";
    }

    const msg = new TextEncoder().encode(`bento-device-attach:${daemonId}:${deviceId}:${ts}`);
    let ok = false;
    try {
      const cryptoKey = await crypto.subtle.importKey("raw", pubkey, { name: "Ed25519" }, false, ["verify"]);
      ok = await crypto.subtle.verify({ name: "Ed25519" }, cryptoKey, sig, msg);
    } catch (e) {
      return `device crypto.verify failed: ${(e as Error).message}`;
    }
    if (!ok) return "bad device signature";

    if (!pinned) {
      // TOFU: pin this device pubkey to the device_id on first valid attach.
      // Devices paired before this code shipped get implicitly upgraded the
      // first time they reconnect with a valid signature.
      await this.state.storage.put(key, toHex(pubkey));
    }
    return null;
  }

  // ============== hibernation-mode WebSocket handlers ==============

  async webSocketMessage(ws: WebSocket, data: ArrayBuffer | string): Promise<void> {
    if (typeof data === "string") {
      // Text frames not used; daemon and iOS both send binary.
      return;
    }
    const a = (ws.deserializeAttachment() ?? null) as Attachment | null;
    if (!a) return;

    if (a.role === ROLE_DAEMON) {
      await this.onDaemonMessage(data);
    } else if (a.role === ROLE_IOS && a.streamId !== undefined) {
      this.onIOSMessage(a.streamId, data);
    }
  }

  async webSocketClose(ws: WebSocket, _code: number, _reason: string, _wasClean: boolean): Promise<void> {
    const a = (ws.deserializeAttachment() ?? null) as Attachment | null;
    if (!a) return;
    if (a.role === ROLE_DAEMON) {
      this.closeAllStreams("daemon disconnected");
    } else if (a.role === ROLE_IOS && a.streamId !== undefined) {
      // Tell the daemon to tear down its end of the SSH stream.
      this.sendDaemonFrame(TYPE_CLOSE, a.streamId, new Uint8Array(0));
    }
  }

  async webSocketError(ws: WebSocket, _err: Error): Promise<void> {
    return this.webSocketClose(ws, 1011, "error", false);
  }

  // ============== daemon → relay frames ==============

  private async onDaemonMessage(buf: ArrayBuffer): Promise<void> {
    const fr = parseFrame(buf);
    if (!fr) return;

    if (fr.streamId === 0 && fr.type === TYPE_CONTROL) {
      await this.handleDaemonControl(fr.payload);
      return;
    }
    const ios = this.findIOS(fr.streamId);
    if (!ios) return;
    if (fr.type === TYPE_DATA) {
      try {
        ios.send(fr.payload);
      } catch {
        this.closeStream(fr.streamId, "ios send failed");
      }
    } else if (fr.type === TYPE_CLOSE) {
      this.closeStream(fr.streamId, "daemon closed stream");
    }
  }

  private async handleDaemonControl(payload: ArrayBuffer): Promise<void> {
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
      const slot: PairingSlot = { code, expiresAt: Date.now() + ttl * 1000 };
      await this.state.storage.put(K_PAIR, slot);
      this.sendDaemonControl({ type: "pair.opened", code, ttl_sec: ttl });
    } else if (t === "pair.cancel") {
      await this.state.storage.delete(K_PAIR);
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
          daemon_label: msg.daemon_label,
        });
      } else {
        pending.resolve({ status: "error", error: msg.error ?? "unknown" });
      }
    } else if (t === "ping") {
      // Echo the nonce so the daemon can correlate request/response and
      // detect "WS protocol alive but app-layer frames dropped" half-death.
      this.sendDaemonControl({ type: "pong", t: Date.now(), nonce: msg.nonce });
    }
  }

  // ============== iOS → relay frames ==============

  private onIOSMessage(streamId: number, buf: ArrayBuffer): void {
    this.sendDaemonFrame(TYPE_DATA, streamId, new Uint8Array(buf));
  }

  // ============== pairing (HTTP) ==============

  private async handlePairOpen(): Promise<Response> {
    if (!this.getDaemon()) return json({ error: "daemon offline" }, 503);
    const slot: PairingSlot = {
      code: mintCode(),
      expiresAt: Date.now() + 60_000,
    };
    await this.state.storage.put(K_PAIR, slot);
    return json({ code: slot.code, ttl_sec: 60 });
  }

  private async handlePair(req: Request): Promise<Response> {
    if (req.method !== "POST") return json({ error: "POST required" }, 405);
    const now = Date.now();

    const lockedUntil = ((await this.state.storage.get(K_LOCKED_UNTIL)) as number | undefined) ?? 0;
    if (lockedUntil > now) {
      return json({ error: "pairing locked", retry_after_ms: lockedUntil - now }, 429);
    }

    const slot = (await this.state.storage.get(K_PAIR)) as PairingSlot | undefined;
    if (!slot || now > slot.expiresAt) {
      return json({ error: "no pairing window open" }, 400);
    }

    let body: { code?: string; device_pubkey?: string; device_label?: string };
    try {
      body = await req.json();
    } catch {
      return json({ error: "bad json" }, 400);
    }

    if (!body.code || body.code !== slot.code) {
      const attempts = (((await this.state.storage.get(K_BAD_ATTEMPTS)) as number | undefined) ?? 0) + 1;
      if (attempts >= MAX_BAD_ATTEMPTS) {
        await this.state.storage.put(K_LOCKED_UNTIL, now + LOCKOUT_MS);
        await this.state.storage.delete(K_PAIR);
        await this.state.storage.delete(K_BAD_ATTEMPTS);
        return json({ error: "too many bad codes; pairing locked" }, 429);
      }
      await this.state.storage.put(K_BAD_ATTEMPTS, attempts);
      return json({ error: "bad code" }, 401);
    }

    if (!body.device_pubkey) {
      return json({ error: "missing device_pubkey" }, 400);
    }
    if (!this.getDaemon()) return json({ error: "daemon offline" }, 503);

    // Burn the slot immediately and reset brute-force counters.
    await this.state.storage.delete(K_PAIR);
    await this.state.storage.delete(K_BAD_ATTEMPTS);

    const reqID = `att-${this.nextAttachId++}`;
    const result = new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingAttach.delete(reqID);
        reject(new Error("daemon did not ack within 10s"));
      }, PAIR_ACK_TIMEOUT_MS);
      this.pendingAttach.set(reqID, { resolve, reject, timer });
    });

    this.sendDaemonControl({
      type: "pair.attach",
      request_id: reqID,
      device_pubkey: body.device_pubkey,
      device_label: body.device_label ?? "",
    });

    try {
      const ack = (await result) as { status: string; device_id?: string; [k: string]: unknown };
      if (ack.status === "ok" && ack.device_id) {
        // Pin the device pubkey for future tunnel auth. Extract the raw 32
        // bytes from the SSH wire-format payload iOS sent (4-byte
        // "ssh-ed25519" name + 4-byte 32-byte key prefix → bytes 19..51).
        const raw = extractRawEd25519FromSSHWire(body.device_pubkey);
        if (raw) {
          await this.state.storage.put(`${K_DEVICE_PREFIX}${ack.device_id}`, toHex(raw));
        }
      }
      const code = ack.status === "ok" ? 200 : 502;
      return json(ack, code);
    } catch (e) {
      return json({ status: "error", error: (e as Error).message }, 504);
    }
  }

  // ============== helpers ==============

  private getDaemon(): WebSocket | null {
    const list = this.state.getWebSockets(ROLE_DAEMON);
    return list.length > 0 ? list[0] : null;
  }

  private findIOS(streamId: number): WebSocket | null {
    const list = this.state.getWebSockets(`stream:${streamId}`);
    return list.length > 0 ? list[0] : null;
  }

  private async allocateStreamId(): Promise<number> {
    // Atomic read-increment-write. Two iOS sockets that open against the same
    // DO at nearly the same instant (e.g. two sessions to one Mac reconnecting
    // together on foreground) would otherwise interleave at the `await` points
    // and both read the same counter → both get the SAME streamId → they share
    // the `stream:N` tag, `findIOS` returns only one, the daemon's
    // `activeSink[N]` is overwritten, and the losing session never receives any
    // data (stuck "reconnecting" forever). `blockConcurrencyWhile` serialises
    // the critical section so every connection gets a distinct id.
    return this.state.blockConcurrencyWhile(async () => {
      const cur = ((await this.state.storage.get(K_NEXT_STREAM_ID)) as number | undefined) ?? 1;
      await this.state.storage.put(K_NEXT_STREAM_ID, cur + 1);
      return cur;
    });
  }

  private sendDaemonFrame(type: number, streamId: number, payload: Uint8Array): void {
    const daemon = this.getDaemon();
    if (!daemon) return;
    try {
      daemon.send(buildFrame(type, streamId, payload));
    } catch {
      // daemon WS broken; will be cleaned up by its close handler
    }
  }

  private sendDaemonControl(obj: unknown): void {
    const payload = new TextEncoder().encode(JSON.stringify(obj));
    this.sendDaemonFrame(TYPE_CONTROL, 0, payload);
  }

  private closeStream(streamId: number, reason: string): void {
    const ws = this.findIOS(streamId);
    if (ws) {
      try {
        ws.close(1000, reason);
      } catch {
        /* ignore */
      }
    }
    this.sendDaemonFrame(TYPE_CLOSE, streamId, new Uint8Array(0));
  }

  private closeAllStreams(reason: string): void {
    for (const ws of this.state.getWebSockets(ROLE_IOS)) {
      try {
        ws.close(1000, reason);
      } catch {
        /* ignore */
      }
    }
  }
}

// ============== wire format ==============

function buildFrame(type: number, streamId: number, payload: Uint8Array): ArrayBuffer {
  const buf = new Uint8Array(HEADER_LEN + payload.byteLength);
  buf[0] = VERSION;
  buf[1] = type;
  new DataView(buf.buffer).setUint32(2, streamId, false);
  buf.set(payload, HEADER_LEN);
  return buf.buffer;
}

function parseFrame(buf: ArrayBuffer): { type: number; streamId: number; payload: ArrayBuffer } | null {
  if (buf.byteLength < HEADER_LEN) return null;
  const view = new DataView(buf);
  if (view.getUint8(0) !== VERSION) return null;
  return {
    type: view.getUint8(1),
    streamId: view.getUint32(2, false),
    payload: buf.slice(HEADER_LEN),
  };
}

function mintCode(): string {
  const n = Math.floor(Math.random() * 1_000_000);
  return n.toString().padStart(6, "0");
}

// extractRawEd25519FromSSHWire decodes the base64 SSH wire-format pubkey
// iOS sends during /v1/pair and returns the raw 32 Ed25519 bytes. SSH
// wire format is:
//   string "ssh-ed25519"   (4-byte length + 11 bytes)
//   string <32 raw bytes>  (4-byte length + 32 bytes)
function extractRawEd25519FromSSHWire(b64: string): Uint8Array | null {
  let bin: string;
  try {
    bin = atob(b64);
  } catch {
    return null;
  }
  // 4 + 11 + 4 = 19-byte prefix, then 32-byte key, total 51 bytes minimum.
  if (bin.length < 51) return null;
  const name = bin.slice(4, 15);
  if (name !== "ssh-ed25519") return null;
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) out[i] = bin.charCodeAt(19 + i);
  return out;
}

function decodeB64Url(s: string): Uint8Array | null {
  // base64url → base64
  let b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  while (b64.length % 4 !== 0) b64 += "=";
  try {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function toHex(b: Uint8Array): string {
  return Array.from(b)
    .map((x) => x.toString(16).padStart(2, "0"))
    .join("");
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
