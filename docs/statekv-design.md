# statekv v2 — per-session keys, revisions, merge-not-replace

Design for fixing the workspace-sync concurrency bugs found in the
2026-07-20 architecture audit. Not yet implemented — the affected files
(`AgentWorkspaceStore.swift`, `host.go`, `AcpRelayTransport.swift`) were
under active parallel edits when this was written; whoever picks this up
should verify line references against HEAD.

## Problems (verified, with evidence)

1. **Whole-blob last-write-wins.** The entire workspace (every session /
   pane / layout) is one blob under the single key `"workspace"`
   (`AgentWorkspaceStore.swift` `scheduleSave`, ~:347-361 — comment says
   "Fire-and-forget; last write wins"). The daemon does a blind replace
   with no version/CAS (`host.go` `setState` ~:86-116; `Control` carries
   only Key+Data). Mac renames a pane in session B while iPhone splits in
   session A → whichever `setstate` lands second silently erases the
   other device's change. This is a direct contradiction of the product's
   core promise (both devices share one session pool).

2. **`statechanged` → wholesale replace.** `onEvent` → `pullRemoteState`
   (~:412-417) → `adopt` (~:443-457) replaces local `state` outright,
   emits full-refresh events for every session (UI flicker on foreign
   geometry-only changes), and shuts down runtimes for panes absent from
   the remote blob. If it lands inside the 1s save debounce, the local
   pending edit is overwritten AND the still-armed save timer re-pushes
   the adopted foreign state as if it were ours.

3. **Offline edits discarded on reconnect.** `syncWithDaemon`
   (~:392-400): daemon has any blob → adopt (local thrown away); local
   state only seeds an EMPTY daemon.

4. **Orphan instances never reaped.** `reconcileInstances` (~:462-472)
   only nils pane→instance links whose agents died. A RUNNING daemon
   instance that no pane references (product of #1/#2 clobbers, or the
   movePane spawn-then-kill placeholder) leaks forever (`gcExited` only
   GCs exited instances).

5. **`getState` continuation slot races.** `AcpRelayTransport.swift`
   keeps ONE pending continuation per op kind (~:104, :268, :347-351),
   matched by arrival order, not key. `statechanged` triggers two
   concurrent getstates (workspace + catalog, store ~:384-388): answers
   can cross-deliver or strand one caller for the 10s timeout. Same
   pattern applies to dirents/filedata if ever parallelized.

## Design

### Key split: one key per session

`workspace` → `ws/<sessionID>` (one blob per session: its panes, layout,
activePane, zoom) + `ws-meta` (tiny: session order/names, or fold into
the existing catalog blob, which already merges — `pullRemoteCatalog`
~:421-437 is the model to follow). Cross-session concurrent edits stop
colliding entirely; the collision window shrinks to "both devices edit
the SAME session simultaneously".

The daemon stays a dumb opaque KV (transport-independence rule: the
daemon never learns the client's schema). `statechanged{key}` already
carries the key, so fan-out granularity comes for free.

### Per-key revision

Each `ws/<id>` blob embeds `{rev: UInt64, device: String, payload}`:

- Writer: `rev = max(lastSeenRev) + 1`, stamped with its device id.
- Reader (statechanged or reconnect): adopt only `rev > local rev`;
  ignore stale echoes (`rev ≤ local`). Equal rev from different devices
  (true simultaneous write): deterministic tiebreak by device id so both
  ends converge without a third state.
- Same-session simultaneous edits remain LWW *at session granularity* —
  accepted; the fix's goal is that Session A edits never clobber
  Session B.

### Adopt → merge

- On `statechanged(ws/<id>)`: pull that key only, replace that session
  only, emit `.structure` for that session only (kills the all-session
  flicker).
- Debounce interaction: if a local save for the same key is pending,
  compare revs — local pending rev will exceed the incoming one, so the
  incoming is dropped and the local push proceeds. No more "adopted
  foreign state re-pushed as ours".
- Runtime teardown on adopt happens only when the *adopted* (newer-rev)
  session omits the pane — a stale blob can no longer kill a
  just-created pane's runtime.
- Reconnect (`syncWithDaemon`): per-key three-way — pull all `ws/*`,
  adopt newer-rev keys, push local keys whose rev is newer, seed keys
  the daemon lacks. Offline structural work survives.

### Migration

First client with v2 reads legacy `workspace`, splits it into
`ws/<id>` keys (rev=1), writes them, deletes the legacy key. Old
clients that only know `workspace` will see an empty blob and rebuild
from the daemon instance list (`reconcileInstances`) — same loud-rebuild
path as the layout-tree fraction migration; fleet = personal devices.

### Transport: keyed continuations

Replace the single `stateCont` slot with `[key: [CheckedContinuation]]`
(answers matched by `statedata.key`), and give dirents/filedata the same
treatment keyed by path. This is independent of the key split and can
land first.

### Orphan reaping (follow-up, lower priority)

After reconcile, an instance that is Running, unreferenced by any pane
in any session, and older than a grace period should surface in the
session picker as an "orphan agent" row (attach or kill) rather than
leak. Auto-kill is NOT safe — the agent may hold un-pushed work.

## Sequencing

1. Keyed continuations in `AcpRelayTransport` (small, independent).
2. Key split + rev + merge in `AgentWorkspaceStore` (+ migration).
3. Orphan surfacing in the pickers.

No daemon changes required for any step.
