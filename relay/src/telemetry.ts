// Telemetry — privacy-first usage counters via Workers Analytics Engine.
//
// Two sources write into the same TELEMETRY dataset:
//
//   1. Server-side aggregation of events the relay already inherently sees
//      (daemon register/connect, pairing outcome, ASR proxy calls). Zero
//      client involvement; only coarse fields — event name, a hash of the
//      daemon_id, engine name. NO IPs, no user content, no payloads.
//
//   2. Client batches POSTed to /v1/telemetry by users who explicitly opted
//      in (the toggle is OFF by default in the apps). Event names are
//      validated against CLIENT_EVENTS below — the server-side mirror of the
//      apps' closed TelemetryEvent enum. Free-form strings are rejected.
//
// All writes are guarded: if the TELEMETRY binding is absent (local dev, or
// the dataset was never provisioned) everything degrades to a no-op and the
// request path is never broken.

/// The complete, closed set of client event names. Mirrors
/// `TelemetryEvent` in bento-terminal-core/Sources/BentoTerminalCore/Telemetry.swift —
/// keep the two lists in sync. Anything not in this set is rejected.
export const CLIENT_EVENTS: ReadonlySet<string> = new Set([
  "first_run_started",
  "first_run_completed",
  "first_run_skipped",
  "agent_wizard_launched",
  "workspace_created",
  "pairing_succeeded",
  "voice_send",
  "voice_first_send",
  "voice_swipe_left_llm",
  "voice_swipe_right_preview",
  "second_agent_opened",
  "mode_toggled",
  "state_awaiting_first_seen",
  "reconnect_resumed",
  "ssh_direct_connected",
  "app_active_day",
]);

const MAX_BODY_BYTES = 16_384;
const MAX_EVENTS_PER_BATCH = 50;

const UUID_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
// App versions like "0.2.0", "1.0.0-beta.3", "0.2.0 (42)".
const APP_VERSION_RE = /^[0-9A-Za-z.+\-() ]{1,32}$/;

/// Server-side event write. `daemonId` is hashed before storage so the
/// dataset never holds the raw routing id. `extra` is a free-form coarse
/// dimension (e.g. "proto:1" on daemon_socket_connected — fleet wire-version
/// distribution). Never throws.
export function logServerEvent(
  dataset: AnalyticsEngineDataset | undefined,
  event: string,
  daemonId?: string | null,
  engine?: string,
  extra?: string,
): void {
  if (!dataset) return;
  try {
    dataset.writeDataPoint({
      // blob1=event, blob2=daemon hash, blob3=engine, blob4=source, blob5=extra
      blobs: [event, daemonId ? fnv1a64(daemonId) : "", engine ?? "", "server", extra ?? ""],
      doubles: [1],
      indexes: [event],
    });
  } catch {
    // Telemetry must never break the request path.
  }
}

/// POST /v1/telemetry handler. Validates the batch strictly (closed event
/// allowlist, UUID install_id, closed platform set, bounded sizes) and
/// writes one data point per event. Returns 204 on success.
export async function handleTelemetryPost(
  req: Request,
  dataset: AnalyticsEngineDataset | undefined,
): Promise<Response> {
  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) {
    return jsonResp({ error: "body too large" }, 413);
  }

  let body: {
    v?: unknown;
    install_id?: unknown;
    platform?: unknown;
    app_version?: unknown;
    events?: unknown;
  };
  try {
    body = JSON.parse(raw);
  } catch {
    return jsonResp({ error: "invalid json" }, 400);
  }

  if (body.v !== 1) return jsonResp({ error: "unsupported version" }, 400);

  const installId = body.install_id;
  if (typeof installId !== "string" || !UUID_RE.test(installId)) {
    return jsonResp({ error: "install_id must be a UUID" }, 400);
  }
  const platform = body.platform;
  if (platform !== "ios" && platform !== "macos") {
    return jsonResp({ error: "bad platform" }, 400);
  }
  const appVersion = body.app_version;
  if (typeof appVersion !== "string" || !APP_VERSION_RE.test(appVersion)) {
    return jsonResp({ error: "bad app_version" }, 400);
  }
  const events = body.events;
  if (!Array.isArray(events) || events.length === 0 || events.length > MAX_EVENTS_PER_BATCH) {
    return jsonResp({ error: `events must be 1..${MAX_EVENTS_PER_BATCH}` }, 400);
  }
  for (const e of events) {
    if (
      !e ||
      typeof e !== "object" ||
      typeof (e as { name?: unknown }).name !== "string" ||
      !CLIENT_EVENTS.has((e as { name: string }).name)
    ) {
      return jsonResp({ error: "unknown event name" }, 400);
    }
    const ts = (e as { ts?: unknown }).ts;
    if (typeof ts !== "number" || !Number.isFinite(ts)) {
      return jsonResp({ error: "bad ts" }, 400);
    }
  }

  if (dataset) {
    const id = installId.toLowerCase();
    try {
      for (const e of events as Array<{ name: string; ts: number }>) {
        dataset.writeDataPoint({
          // blob1=event, blob2=platform, blob3=app_version, blob4=source
          blobs: [e.name, platform, appVersion, "client"],
          doubles: [e.ts],
          indexes: [id],
        });
      }
    } catch {
      // Never fail the request over a telemetry write.
    }
  }
  return new Response(null, { status: 204 });
}

/// Synchronous FNV-1a 64-bit hash (hex). Cheap, dependency-free, good enough
/// for cardinality counting without storing raw daemon ids.
function fnv1a64(s: string): string {
  let h = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  const mask = 0xffffffffffffffffn;
  for (let i = 0; i < s.length; i++) {
    h ^= BigInt(s.charCodeAt(i));
    h = (h * prime) & mask;
  }
  return h.toString(16).padStart(16, "0");
}

function jsonResp(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
