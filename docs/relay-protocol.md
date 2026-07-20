# Relay wire protocol — versioning & flow control

Canonical policy for the daemon ↔ relay framing layer. The implementations
live in `desktop/internal/relay/` (Go, daemon side) and `relay/src/daemon-do.ts`
(TypeScript, Cloudflare Durable Object). This document is the tie-breaker when
the two drift.

## Topology

```
iOS app ── WSS (acphost units, no framing) ── DaemonDO ── WSS (framed) ── bento-daemon
                                              1 per daemon_id
```

Only the **daemon leg** is framed. The iOS leg carries opaque acphost units
(E2E-encrypted, see below); the DO maps each iOS socket to a `stream_id` and
multiplexes all of them over the single daemon socket. Nothing at the relay
layer parses the payload.

**Payload since the ACP-native rebuild:** each stream is one agent session.
The payload protocol ("acphost") is length-prefixed units: a signed X25519
handshake bound to the pairing-time Ed25519 identities, then
ChaCha20-Poly1305-sealed control JSON + agent stdio (newline-delimited
JSON-RPC / ACP). Canonical spec: the package comment in
`desktop/internal/acphost/proto.go`. The relay never sees plaintext — the
role SSH played in the terminal-based version.

## Wire format (version 0x01)

```
0       1     2                   6                     N
+-------+-----+-------------------+---------------------+
|version| type| stream_id(uint32) | payload             |
+-------+-----+-------------------+---------------------+
                big-endian
```

| type | name    | payload                                      |
|------|---------|----------------------------------------------|
| 0x01 | open    | empty — DO tells daemon a stream attached    |
| 0x02 | data    | opaque acphost units (E2E encrypted)         |
| 0x03 | close   | empty                                        |
| 0x10 | control | JSON, stream_id 0 only                       |

The header layout is unchanged from the SSH era, so the frame version stays
0x01 — payload semantics are invisible to the relay (see Versioning).

Control JSON types today: `pair.open`, `pair.opened`, `pair.cancel`,
`pair.attach`, `pair.ack`, `ping`, `pong`.

## Versioning & evolution

The fleet cannot be upgraded atomically: the relay redeploys in seconds, but
daemons on users' Macs and apps on phones lag by weeks. Every wire change must
be classified:

**Non-breaking (no version bump) — prefer this:**

- New control-JSON message types. Both receivers ignore unknown types
  (`pairing.Manager.OnControl` switch falls through; DO `handleDaemonControl`
  if-chain falls through).
- New frame types. Both receivers ignore unknown type bytes (Go `handle`
  switch has no default action; DO `onDaemonMessage` only dispatches known
  types).
- New fields inside existing control messages (readers use lenient lookups).

**Breaking (version bump required):** any change to the 6-byte header layout
or to the semantics of an existing type. Procedure:

1. Deploy the relay first, supporting **both** the new version and every
   version the fleet still speaks. The relay never drops support for a
   version while `daemon_socket_connected` telemetry (blob5 `proto:N`) still
   shows daemons using it. `proto:legacy` = daemon predates the param.
2. Ship the daemon update; watch the proto distribution converge.
3. Only then may old-version support be retired.

**Mismatch is loud, never silent.** A wrong version byte is deterministic
skew — every subsequent frame fails identically — and used to produce the
worst failure mode we know: a healthy-looking socket that moves no traffic.
Both ends now fail fast:

- DO receiving an unknown version: emits `wire_version_mismatch` telemetry
  and closes the daemon socket with code **4002**.
- Daemon receiving an unknown version (`ErrVersionMismatch`) or seeing close
  4002: ends the session with an explicit "update bento-daemon" message in
  `LastError` (surfaced by `/v1/status`), then retries with normal backoff.

### WS close-code registry (relay-originated)

| code | meaning                                | daemon reaction              |
|------|----------------------------------------|------------------------------|
| 4000 | daemon socket replaced by newer connect| reconnect with backoff       |
| 4002 | frame wire version unsupported         | fatal status + backoff retry |

Constants: `CLOSE_*` in `daemon-do.ts` ↔ `StatusWireVersionUnsupported` in
`client.go`. Keep in sync.

## Flow control

**The relay layer has NO windowing, by design — and that is only safe because
of an invariant, not luck:**

> Relay streams MUST carry payloads that are themselves end-to-end
> flow-controlled. In the SSH era that was the SSH channel window; today it
> is the acphost credit window.

Why the relay can't do it itself: workerd does not expose
`WebSocket.bufferedAmount` ([cloudflare/workerd#988]), so the DO cannot see
how many bytes are queued toward a slow phone; `send()` always "succeeds".
With no congestion signal there is nothing to build pause/resume on. The
bound must come from the payload protocol.

Verified bounds (2026-07, acphost v1):

- **daemon → phone**: acphost stdio is credit-windowed. The daemon stops
  reading agent stdout once `InitialWindow` (**256 KiB**) of un-credited
  bytes are in flight; the client grants credit as it consumes. This caps
  what the DO can ever buffer toward one slow phone (overshoot: at most one
  in-flight chunk, ≤ `StdioChunk`).
- **phone → daemon**: prompts and control messages are small or chunked;
  the child's stdin pipe provides natural backpressure. No explicit window.
- **Unit cap is a sender obligation.** `MaxUnit` (1 MiB) is enforced on
  RECEIVE and tears the transport, so every large payload is chunked at
  the sender: stdio lines split at `StdioChunk` (256 KiB; both ends
  reassemble the byte stream on newlines, so chunk boundaries carry no
  meaning), and `readfile` responses split the base64 across several
  `filedata{more:true}` control messages (≤512 KiB each). A single agent
  JSON-RPC line is bounded at `maxAgentLine` (32 MiB) — anything longer is
  dropped with a stderr notice, never by killing the read loop.
- The control sub-channel (`filedata`, `dirents`, `stderr`, statekv) is
  NOT credit-windowed; its bursts are bounded by the chunk caps above
  (worst case ≈ a 2 MiB file preview ≈ 2.7 MiB of base64 across ~6 units).

With the DO memory limit at 128 MB, worst-case buffering of
window × streams stays two orders of magnitude below it for any realistic
session count.

**Consequences:**

- Piping a NON-flow-controlled payload through a stream (a future raw-TCP
  forward, an unthrottled event feed) would reopen unbounded DO buffering.
  That feature must bring its own app-level windowing.
- Don't raise `InitialWindow` for throughput without re-doing this
  arithmetic.

### Liveness probes vs. bulk data

Probes (WS protocol ping + app-level `{"type":"ping"}`) share the daemon
socket and its write mutex with stream data. On a slow uplink a bulk transfer
can starve a probe past its timeout while the link is healthy. The daemon
therefore forgives up to 3 consecutive probe failures *while WS writes are
still completing* (`livenessGate`, `maxGracedProbes`). The cap is
load-bearing: on a half-open socket writes also keep "succeeding" into the
kernel buffer, so uncapped grace would disable half-death detection — the
bug the app-level ping exists to catch. Net effect: ≤90 s added detection
latency in exchange for not tearing down every session whenever someone
`cat`s a big file on hotel Wi-Fi.

## Telemetry hooks (server-side, `logServerEvent`)

- `daemon_socket_connected` — blob5 `proto:N` / `proto:legacy`: fleet wire
  version distribution. Check before any breaking change.
- `wire_version_mismatch` — blob5 `got:N-want:M`. Steady state is **zero**;
  any occurrence means a botched rollout or a rolled-back relay.

[cloudflare/workerd#988]: https://github.com/cloudflare/workerd/issues/988
