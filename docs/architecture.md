# Bento architecture

2026-07-20. The post-refactor map: what runs where, who owns what, and the
few rules that keep it simple. (History: the product began as a tmux/SSH
terminal; the terminal, tmux, and SSH stacks were removed when agents moved
to ACP. See git history for the old design docs.)

## The one-paragraph version

Bento is a multi-device UI for **parallel ACP coding agents**. A Go daemon
on the Mac **hosts the agent processes** so they outlive any client. The
shared Swift package **BentoCore** owns the workspace model (workspaces ⊃
panes ⊃ one agent conversation each) and the chat UI; the macOS and iOS
apps are thin shells around it. A Cloudflare Worker **relay** gives paired
iOS devices an end-to-end-encrypted pipe to the daemon. No accounts;
pairing is the identity.

```
┌─ iOS app ───────┐       ┌─ Cloudflare relay ─┐       ┌─ Mac ─────────────────────────────┐
│ WorkspaceScreen │◄─wss─►│  pairing + E2E-    │◄─wss─►│ bento-daemon (Go, launchd)        │
│ AgentChatVC ×N  │       │  encrypted streams │       │  ├─ agent processes (ACP, stdio)  │
│ voice compass   │       └────────────────────┘       │  ├─ conversation event logs       │
└─────────────────┘                                    │  ├─ statekv (workspace mirror)    │
                                                       │  └─ unix socket                   │
                                                       │        ▲                          │
                                                       │  Mac app (menubar + window) ──────┘
                                                       └───────────────────────────────────┘
```

## Modules

### `acpkit` — the protocol package

- **ACPKit**: pure Agent Client Protocol — JSON-RPC framing, schema types,
  `ACPConnection`. No dependencies, no UI.
- **BentoLink**: the link layer beneath everything — acphost framing +
  sealed-handshake vocabulary (`AcpSealedConfig`; the seal belongs to the
  pairing, not the relay), the `AcpByteLink` bearer protocol, and both
  bearers (unix socket, relay WSS; LAN-direct slots in here). Knows
  NOTHING of ACP — that ignorance is load-bearing.
- **ACPHostKit**: the sealed transport engine + `ACPTransport` adapter,
  agent launchers, `ACPAgentPreset` (the builtin agent catalog: command,
  args, login hints). Re-exports BentoLink.

### `bento-core` — the shared Swift core (umbrella module `BentoCore`)

Seven targets + an umbrella; the Package.swift dependency arrows *are*
the architecture, and SPM enforces them (an illegal import is a build
error, not a review comment). Apps and tests `import BentoCore` — the
umbrella `@_exported`s everything. Cross-module access inside the
package is `package`-level, never blanket-`public`.

| Target | Owns |
|---|---|
| `BentoFoundation` | `Host`, logging, telemetry, `TipCenter`, `AgentSpec`/`AgentPreset` + `AgentDefaults` (the scene-level agent catalog), voice vocabulary (`VoiceSink`) |
| `BentoUI` | `ThemeStore`/`CanvasTheme`, `PaneState` (the state language + its palette) |
| `BentoVoiceKit` | Hold-to-talk: `VoiceSession`, speech engines (Apple / Qwen realtime), audio capture, batch "AI correct", compass overlay |
| `BentoFilePreviewKit` | Preview core (source protocol + local/relay sources), web renderer (highlight.js / markdown-it) + PathPreview assets, tree browser/search |
| `BentoWorkbench` | `AgentWorkspaceStore` (THE source of truth), `LayoutTree`, `WorkspaceTypes`, daemon statekv mirror, `SessionCatalog`, `WorkspaceViewModel`/`PaneViewModel`, `PaneSidebar`, drop zones — **and the two seams**: `PaneRuntime` (what runs in a pane, without knowing agents) and `StructureAuthority` (who writes structure). May not import any pane module, by manifest. |
| `BentoAgentPane` | The ACP pane: `AgentSessionViewModel` (+ `PaneRuntime` conformance, installed via `AcpPaneModule.install`), transcript models, the chat UI, providers + connect flow, `AgentChatSurface` (Mac) |
| `BentoShellMac` | The AppKit shell: `WorkspaceWindow`, `WorkspaceToolbar`, `TiledPaneHost`, command palette, preview dock, history panel, voice controller, notifier, `ShellMacWiring` (hands shell chrome to modules that must not import it) |

### Apps

- **`BentoMenubar/` (macOS)**: menu bar item + Settings + onboarding
  wizard + pairing windows. The workspace window itself lives in
  `BentoCore/Mac` so the app target stays a shell. Wires
  `DaemonAgentLauncher` (unix socket) into the shared store at launch.
- **`Bento/` (iOS)**: pairing (QR → relay), host list, workspace picker,
  `WorkspaceScreen` (tiled/focus pane grid hosting `AgentChatVC`s), voice
  input controller. Wires `RemoteAgentLauncher` (relay) into a per-daemon
  store.

### `desktop/` — Go daemon + CLI

- `internal/acphost`: hosts agent processes (spawn/attach/detach/kill),
  multiplexes multiple subscriber clients per agent, statekv, sealed-frame
  crypto for relay clients. Keyed by CONVERSATION as well as by process: a
  spawn that names its ACP session adopts the live agent for it instead of
  starting a rival, and each conversation owns a durable event log
  (`~/.bento-acp/conversations/<id>/`, memory tail + segmented JSONL) that
  outlives both the agent process and the daemon.
- `internal/pairing`, `internal/hostidentity`: 6-digit-code pairing; the
  daemon's Ed25519 identity key + authorized device keys (OpenSSH key
  *formats* only — there is no SSH server).
- `internal/relay`: WSS tunnel client to the Worker.
- `internal/ipc`: local unix-socket control plane (Mac app / CLI).
- Runs under launchd (`bento tunnel start` installs the LaunchAgent).

### `relay/` — Cloudflare Worker

Pairing rendezvous + dumb encrypted pipe (it can't read agent traffic) +
ASR/LLM proxy so voice works with zero configuration. Protocol:
[relay-protocol.md](relay-protocol.md).

## The rules that keep it simple

1. **The store is the only writer of structure.** Views call verbs on
   `AgentWorkspaceStore` (split/select/zoom/move/rename/kill); everything
   else observes. `WorkspaceViewModel` is a facade binding one workspace to
   one window — it holds no structure of its own.
2. **Agents persist in the daemon; conversations persist in the agent.**
   A pane records `(instanceID, acpSessionID)`. Reattach when the process
   is alive; respawn + `session/load` when it isn't. Killing a pane
   *graduates* its conversation into the history catalog.
   The agent's own storage stays the TRUTH — the daemon's event log is a
   projection of it, rebuildable by `session/load`. It exists because that
   call has no pagination: catch-up reads a cursor'd slice of the log
   instead of replaying a months-long conversation. A respawn therefore
   names the conversation, so the daemon binds the existing log (and
   refuses to run two processes on it) rather than starting a second one.
3. **Cross-device sync is per-workspace last-write-wins.** The store mirrors
   each workspace under its own statekv key with a `(rev, origin)` guard
   (see [statekv-design.md](statekv-design.md)); the history catalog
   merges by union. No tombstones; dirty local copies resurrect.
4. **Layout is fractional.** `LayoutTree` lives on a unit canvas; views
   multiply fractions by their own bounds. (Pane geometry still projects
   onto a legacy 160×48 grid for `Pane.width`-style Int consumers and the
   resize step unit.)
5. **Pane state is protocol truth.** working = turn in flight, awaiting =
   pending permission/question/auth, done-unseen = finished while
   unfocused. No output parsing.
   Truth for EVERY viewer, not just the one driving: the daemon broadcasts
   both halves of a turn (`turnStarted` / `turnDone`) and tells the other
   viewers when an agent request has been answered, because first-answer-wins
   means nothing else will ever mention it again. A request about the host
   (fs, terminal) is answered by the daemon and never shown to a viewer at
   all — a phone has neither the files nor the processes.
6. **The relay stays dumb.** Pairing, encrypted bytes, and provider
   proxying only — intelligence never moves server-side.

## Testing

- `bento-core`: `swift test` — workspace store/migration/mirror, layout
  tree, agent session VM (scripted transport), catalog, palette/file
  search, preview assets.
- `acpkit`: `swift test` — framing, connection, schema, host-client
  vectors (shared with the Go side via `cmd/acpvectors`).
- `desktop`: `go test ./...` — acphost lifecycle, pairing, relay framing.
- Apps: `xcodebuild` schemes `Bento` (iOS) / `BentoMenubar` (macOS);
  iOS simulator loop in `scripts/ios-dev.sh`, Maestro flows in
  `tests/maestro/`.

### The frozen terminal product (Bento Term)

The repo also builds the terminal product, frozen at the pre-merge
terminal branch: apps `BentoTerm` (iOS) / `BentoTermMenubar` (macOS) from
`BentoTermApp/`+`BentoTermMenubar/`, packages `bento-terminal-core` +
`swift-tmux` (own tests: `swift test` in each), and its own Go daemon in
`desktop-term/` (`go test ./...`; the two daemons stay separate binaries
until the tmux host lands in the main daemon). Feature claims between the
two shells are ledgered in `docs/merge-claims.md`.
