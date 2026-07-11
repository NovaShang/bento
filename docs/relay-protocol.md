# Relay wire protocol — versioning & flow control

Canonical policy for the daemon ↔ relay framing layer. The implementations
live in `desktop/internal/relay/` (Go, daemon side) and `relay/src/daemon-do.ts`
(TypeScript, Cloudflare Durable Object). This document is the tie-breaker when
the two drift.

## Topology

```
iOS app ── WSS (raw SSH bytes, no framing) ── DaemonDO ── WSS (framed) ── bento-daemon
                                              1 per daemon_id
```

Only the **daemon leg** is framed. The iOS leg carries opaque SSH ciphertext;
the DO maps each iOS socket to a `stream_id` and multiplexes all of them over
the single daemon socket. Nothing at the relay layer parses SSH.

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
| 0x02 | data    | opaque SSH bytes                             |
| 0x03 | close   | empty                                        |
| 0x10 | control | JSON, stream_id 0 only                       |

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
> flow-controlled (today: SSH). The SSH channel window is the relay's
> in-flight byte bound.

Why the relay can't do it itself: workerd does not expose
`WebSocket.bufferedAmount` ([cloudflare/workerd#988]), so the DO cannot see
how many bytes are queued toward a slow phone; `send()` always "succeeds".
With no congestion signal there is nothing to build pause/resume on. The
bound must come from the payload protocol.

Verified bounds (2026-07, pinned versions):

- **daemon → phone**: NIOSSH advertises `maximumPacketSize` (default
  `1 << 17` = **128 KiB**) as the per-channel window
  (`SSHChannelMultiplexer.swift`). This caps what the DO can ever buffer
  toward one slow phone channel. Guard comment at the `NIOSSHHandler` init in
  `BentoRelayClient.swift`.
- **phone → daemon**: x/crypto/ssh advertises 64 × 32 KiB = **2 MiB** per
  channel (`ssh/channel.go`), capping DO buffering toward a slow daemon.
- Daemon-side output batching adds ≤16 KiB per stream (`batchMaxBytes`).

With the DO memory limit at 128 MB, worst-case buffering of
window × channels stays two orders of magnitude below it for any realistic
session count.

**Consequences:**

- Piping a NON-flow-controlled payload through a stream (a future raw-TCP
  forward, an unthrottled event feed) would reopen unbounded DO buffering.
  That feature must bring its own app-level windowing and a version bump.
- Don't raise the iOS `maximumPacketSize` / window for throughput without
  re-doing this arithmetic.

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
