# Bento Term Mac on trunk — shell port worklist

2026-07-29. Read-only reconnaissance for P7 step 6/H ("Term Mac 外壳装配" —
docs/tmuxpane-design.md hands this doc to H). Compares the frozen product-B Mac
shell (`frozen/bento-terminal-core/Sources/BentoTerminalCore/*_macOS.swift` +
`apps/BentoTermMac/Sources`) against trunk (`modules/BentoShellMac` +
`modules/BentoTerminalPane`), and says what ports where when `frozen/` is
deleted. Transport is BentoLink only; the tmux client stack
(swift-tmux, `TerminalViewModel*`, `LocalPty*`, SSH) retires with `frozen/`.

Companion doc: [term-ios-port.md](term-ios-port.md). Daemon side:
[tmux-host-design.md](tmux-host-design.md). Client pane side:
[tmuxpane-design.md](tmuxpane-design.md).

## 0. Layer verdict up front

- **Surface layer is already ported.** Trunk `BentoTerminalPane` is the frozen
  rendering base moved wholesale: `GhosttyTerminalSurface.swift` (iOS) is
  byte-identical; `GhosttyTerminalSurface_macOS.swift`, `GhosttyRuntime.swift`,
  `StateDetectionService.swift`, `PaneState.swift` differ only by deliberate
  decoupling (path-preview → callbacks, SwiftTmux types → private copies,
  ThemeStore → pushed values). `PaneSearchBar_macOS.swift`,
  `PaneHintChip_macOS.swift`, `TerminalSizingMode.swift`, `ScrollReviewCompose`,
  `PathDetection`, `PredictiveEcho`, `AgentStatusRules` are identical.
- **The tmux session brain dies.** Frozen `TerminalViewModel.swift` (1,980) +
  `TerminalViewModel+Structure.swift` (1,024) + `PaneViewModel.swift` (251) are
  the client-side `tmux -CC` parser/owner; on trunk the daemon owns tmux
  (`daemon/internal/tmuxcm`, `daemon/internal/host/tmux`) and the client is
  BentoTmuxPane (`TmuxPaneRuntime` + `DaemonAuthority` + statekv projection).
- **The shell/window layer is the actual port.** Frozen
  `GhosttyTerminalWindow_macOS.swift` (1,474) +
  `GhosttyTerminalTabBar_macOS.swift` (771) + `WindowSidebar.swift` (415) +
  parts of `GhosttyTiledPaneHost_macOS.swift` (2,267) have **no trunk
  equivalent with the same shape**: trunk `WorkspaceWindow_macOS.swift` (1,152)
  is a single-window self-managed-tab shell for product A.

## 1. Feature-by-feature table

Columns: trunk status ∈ {exists / exists-different / missing}; action ∈
{reuse trunk / port from frozen / drop}. "BSTM" = proposed new module
`modules/BentoShellTermMac` (§2).

| # | Feature | Frozen anchor | Trunk status | Action | Lands in | Size | Gates on |
|---|---|---|---|---|---|---|---|
| 1 | **Native window tabs** — one tmux session per NSWindow, joined by `tabbingIdentifier` (`"bento.terminal"`), AppKit tab bar, ⌘⇧[/], drag-out, Merge All | `GhosttyTerminalWindow_macOS.swift:19-292` (managers list 21, addWindow 232-257, tabbingIdentifier 482, tabbingMode rationale 483-490), `NewSessionPlacement` 193-222, tab `+` → `newWindowForTab` 807-810 & `apps/BentoTermMac/Sources/App/AppDelegate.swift:186-192` | **exists-different** — trunk is ONE window + self-managed toolbar segment strip (`WorkspaceWindow_macOS.swift:17-22, 227-260`) | port from frozen (this is B's identity: session = native tab) | BSTM (`TermWindowManager`, one per session) | L (~1.0-1.2k lines adapted) | statekv `tmux/<target>/structure` mirror (daemon step 4) for the session list; TmuxPaneModule for content |
| 2 | **Toolbar** — `[▢ session ⌄][Parallel│Focus] — [window strip \| search] — [＋New ⌄][⚙][▤]`; center = tmux WINDOWS (`index:name`), sessions menu on the left with filled/ring dots; right-click a segment → window actions | `GhosttyTerminalTabBar_macOS.swift:12-19` (layout), 46-54 (sessions+dots), 66-78 (window group), 75-78 (onWindowMenu); strip rebuild `GhosttyTerminalWindow_macOS.swift:1000-1069`; segment context menu 1275-1310 | **exists-different** — trunk `WorkspaceToolbar_macOS.swift` centers SESSION tabs, no search field, no sizing menu, adds Focus agent-title (204) and move-tab-left/right | port from frozen, re-source windows/dots from statekv + AgentStatusRules | BSTM (`TermToolbarController`) | M-L (~800) | statekv windows + per-window state aggregation |
| 3 | **Search field → palette** — center search field (or compact magnifier when the strip is up) opens the command palette anchored so the panel COVERS the field | `GhosttyTerminalTabBar_macOS.swift:103-115, 190-211, 244, 253-271`; anchored presentation `frozen .../CommandPaletteController_macOS.swift:24-85` | **missing** — trunk palette exists but dropped the `anchorView` presentation (`modules/BentoShellMac/CommandPaletteController_macOS.swift:29-65`, diff confirms removal) | port from frozen (small, additive; could be restored in the shared controller so A can adopt later) | shared chrome (§2.2) or BSTM | S (~80) | none |
| 4 | **Shell menu** — ⌘P palette, ⌥⌘P preview, find family, **⌘T = New tmux Window / ⇧⌘T = New Session / ⌥⇧⌘T = no-tmux**, Split Right(-h) ⌘D / Split Down(-v) ⇧⌘D, ⌘]/⌘[ panes, ⌥⌘↑/↓ swap, ⇧⌘↩ zoom, ⌘0-9 windows, ⇧⌘R track size, ⌘W/⇧⌘W close | `apps/BentoTermMac/Sources/App/BentoMenubarApp.swift:53-125` (⌘T rationale 74-79, ⌘0-9 102-112, ⇧⌘R 113-117) | **exists-different** — trunk Panes menu (`apps/BentoMac/Sources/App/BentoMenubarApp.swift:66-122`): ⌘T = new workspace window, ⌘1-9 = select PANE, ⌘F = transcript find, no sizing/no-tmux items | port from frozen verbatim (B keeps term semantics; per docs/merge-claims.md the find four + ⌘T rethink are claimed for Bento Term — ⌘T/Split wording were flagged "须用户确认" there, but faithful-to-frozen IS the brief; confirm only if deviating) | `apps/BentoTermMac` (`TerminalCommands` stays app-level) | S (~130, mostly re-pointing selectors) | selector table in BSTM tiled host (#6, #7) |
| 5 | **Find ⌘F/⌘G/⇧⌘G/⌘E — scrollback-scoped** (trunk's ⌘F is transcript-scoped) | selectors `GhosttyTiledPaneHost_macOS.swift:1294-1319`, `BentoPaneAction` 1400-1439; surface half: `beginSearch/findNext/findPrevious/useSelectionForFind` + `PaneSearchBar` | **half-exists** — surface half fully in trunk (`modules/BentoTerminalPane/PaneSearchBar_macOS.swift` identical; search lives in `GhosttyTerminalSurface_macOS`); responder-chain half missing | port the selector/дispatch half | BSTM tiled host + `apps/BentoTermMac` menu | S (~60) | #6. ⚠️ behavioral caveat: after a cursor'd attach the surface holds only replayed scrollback (eventlog window + `capture-pane` fallback, tmux-host-design §instance.go) — ⌘F searches what was fed, which may be less than the frozen product's full local scrollback |
| 6 | **Tiled pane host (Parallel view)** — tmux window's panes tiled 1:1, cell-exact sizing (+1 cell ghostty fudge), divider drag, drag-to-dock, mode badge (copy-mode / mouse-off), pane title bars | `GhosttyTiledPaneHost_macOS.swift` (2,267): mode badge 1281-1292, palette present 1044-1053, window-scoped verbs throughout | **exists-different** — trunk `TiledPaneHost_macOS.swift` (1,154) is fractional-LayoutTree, hardcodes `AgentChatSurface` (line 224); has drop zones, divider overlay, voice, first-responder perf guard (675-685) | **reuse trunk host + PaneModule registry** (tmuxpane-design §PaneModule: "makeCell 走注册表"), then port the tmux-only bits: cell-exact fit math, mode badge, window-index verbs. Do NOT fork a second host unless cell-exactness proves incompatible with the fractional tree | `modules/BentoWorkbench` (registry) + `modules/BentoTmuxPane` (surface factory) + BSTM (host wiring) | M (registry S; cell-fit + badges ~300) | PaneModule registry (G step 2); tmux layout → LayoutTree readonly projection |
| 7 | **⌘0-9 select window by tmux INDEX** (sparse indices honored) | `GhosttyTiledPaneHost_macOS.swift:1333-1354` + menu `BentoMenubarApp.swift:102-112` | **exists-different** (trunk ⌘1-9 = panes) | port from frozen | BSTM host selectors | S (~40) | windows-in-session read from statekv |
| 8 | **Track Session Size ⇧⌘R + sizing menu + owner UX** — sticky policy = tmux `window-size` (`latest/smallest/manual`), owner in `@bento_size_owner`, adopt-don't-write on attach, auto-release on `%client-detached`, "set by \<device\>" menu note | type: `TerminalSizingMode.swift` (identical in trunk); UI: `GhosttyTerminalTabBar_macOS.swift:31-37, 570-601`, `GhosttyTerminalWindow_macOS.swift:86-92`; ENFORCEMENT: `TerminalViewModel+Structure.swift:622-770` (sizeOwnerOption 622, adoptSizingPolicy 663-688, setSizingMode 709-716, detach release 761+) | **type exists, logic dies with the VM.** tmux-host-design's protocol has `resize` only — **no sizing-policy op exists or is designed**; tmuxpane-design just says "尺寸权威三策略是 daemon 侧 seam，客户端只发意图" | port the MENU + intent-sending client-side; the policy/owner state machine must be REWRITTEN in `daemon/internal/host/tmux` (it owns the control client, so `list-clients`/`%client-detached` land there naturally) | daemon `host/tmux` + BSTM toolbar | M client / M daemon | ⚠️ **undesigned daemon seam — biggest protocol gap this port has** (also gates iOS §2.5 UX) |
| 9 | **Sidebar (Focus)** — rows = tmux WINDOWS: live name, state glyph, rename (kills auto-rename), Move to Session (incl. New Session + landing choice), close-with-confirm, New Window (duplicate current / path+command) | `WindowSidebar.swift` (415; rows 141+, move 117+, forms 290-415); host wiring `GhosttyTerminalWindow_macOS.swift:707-739` (mode-driven, pinned open in Focus) | **exists-different** — trunk `PaneSidebar` (BentoWorkbench, rows = PANES, no rename) | port WindowSidebar re-sourced from statekv windows + structure verbs; keep trunk's hosting pattern (both shells host a SwiftUI sidebar in `NSSplitViewItem` identically) | BSTM (or BentoTmuxPane if iPad shares it — frozen file was cross-platform) | M (~400) | structure verbs (`renameSession`/`movePane`… via DaemonAuthority) + windows mirror |
| 10 | **Session strip / dormant switcher** — left button menu lists EVERY session on the machine; filled dot = open here (colored by agent activity: amber awaiting → green done-unseen → blue working → gray idle), hollow ring = dormant; native tab titles carry a colored ● | dots/menu `GhosttyTerminalWindow_macOS.swift:1013-1023, 1119-1192`; tab attributedTitle 1127-1140; feed: `AppDelegate.swift:210-229` (5s `TmuxCLI.listSessions`/`listWindows` poll → `setServerSessions`) | **exists-different** — trunk has the same dot language on its segment strip (`WorkspaceWindow_macOS.swift:963-1032`) | port frozen model; replace the CLI poll with statekv subscription (no polling — the mirror pushes) | BSTM + `apps/BentoTermMac` (AppDelegate keeps only daemon-status poll) | M (~300) | statekv structure mirror |
| 11 | **Quit/reopen semantics** — `isTerminating` set in `applicationShouldTerminate` BEFORE windows close so the reopen list records the whole set; per-tab close prunes the list; last-window close does NOT wipe it; reopen prunes names the server no longer has; plain tabs never persisted; frame autosave OWNER handed back on close | `AppDelegate.swift:121-127`; `GhosttyTerminalWindow_macOS.swift:135-146` (persist + isTerminating 144), onEmpty guard 234-246, reopen prune 106-133, frame owner 607-615 + 629-639 + 1400-1412 | **partially exists** — trunk has the frame fix for its single window (`WorkspaceWindow_macOS.swift:1115-1123`, comment cites term's eff25ec) but no `isTerminating`/owner-handoff because it never has N windows | port from frozen with the multi-window model (it is inseparable from #1) | BSTM + `apps/BentoTermMac` AppDelegate | S (~120) | #1 |
| 12 | **Plain (no-tmux) tabs, SSH quick-connect tabs, `newCommandWindow`** (FirstRun runs agent installs in a VISIBLE terminal) | `GhosttyTerminalWindow_macOS.swift:148-190, 280-287`, plain SessionTab 346-373; `LocalPtyTransport_macOS.swift` (54) + `LocalPty_macOS.swift` (155); `SSHConfigHosts_macOS.swift` (98) | **missing, and the transport is undefined on trunk** — LocalPty stays behind in frozen; daemon has no pty instance kind (that's the product-A hybrid plan, docs/hybrid-workbench-design.md §3, not tmux-host-design) | DECISION NEEDED. Options: (a) port `LocalPty*` into BSTM as an app-local transport for plain tabs (~210 lines, keeps FirstRun working, no daemon persistence); (b) defer plain/SSH tabs to the daemon pty kind; (c) drop. Recommend (a) for v1 — FirstRun's install flow and "New Window (no tmux)" are shipped behavior. SSH quick-connect (`ssh <host>` in a plain tab, ~/.ssh/config list) rides whichever option wins — it is NOT the Citadel stack (that dies with iOS direct-connect) | BSTM | S-M (~350 incl. SSHConfigHosts) | product decision; none technical if (a) |
| 13 | **Theme / chrome color / menubar residency** — LSUIElement accessory ⇄ regular flips; window chrome wears the ENGINE-reported terminal bg (`reportedChromeColor` via `.ghosttySurfaceBackgroundChanged`, theme fallback); appearance pinning; `makeTerminalTheme()` (fonts + 16-color ansi) + `.itermcolors` import | residency `GhosttyTerminalWindow_macOS.swift:152-155, 267-268`; chrome color 656-705; appearance `AppDelegate.swift:137-157`; themes `TerminalThemeStore.swift:103-115, 273` | **mostly exists** — residency + appearance identical on trunk (`WorkspaceWindow_macOS.swift:111-114`, `apps/BentoMac .../AppDelegate.swift:163-186`); trunk `BentoUI/ThemeStore` already has `TerminalColorTheme.builtIn` + `fromITermColors` (24-140) but only `makeCanvasTheme()` (239); trunk runtime re-posts the theme notifications (`modules/BentoTerminalPane/GhosttyRuntime.swift:25-31`); `reportedChromeColor` adoption absent from trunk window | reuse trunk residency/appearance; port chrome-color adoption + a `makeTerminalTheme()` bridge (BentoUI cannot import BentoTerminalPane, so the ThemeStore→`TerminalTheme` mapping lands in BSTM or as a BentoTmuxPane helper) | BSTM | S (~150) | none |
| 14 | **Preview dock, palette, voice controller, awaiting notifier, new-pane panel, history panel** | frozen `PreviewDock_macOS.swift` (485), `CommandPalette*.swift` (306+484), `MacVoiceController_macOS.swift` (228), `MacTerminalNotifier_macOS.swift` (74), `NewPaneDirectoryPanel_macOS.swift` (104), `FilePreviewPanel_macOS.swift` (376) | **exists** — trunk BentoShellMac carries adapted versions of all six (diffs vs frozen: 172/44+6/159/≈notifier renamed `MacAwaitingNotifier` 80/133/196 lines) | **reuse trunk** — but see §2.2: every BentoShellMac file currently `import BentoAgentPane`, and B must not link the ACP pane. Extraction or duplication decision required | shared chrome module (§2.2) | S if extraction is clean; M if symbols are entangled | audit of real BentoAgentPane symbol use (unknown — imports are blanket-style) |
| 15 | **Kill/detach/rename session, window absent-poll self-close, rename re-home close** | `GhosttyTerminalWindow_macOS.swift:869-907` (kill via one-shot CLI), 831-847 (absentPolls 414-421), 971-998 (migrateSessionKey; re-homed → close) | **exists-different** — trunk versions exist for workspaces (`WorkspaceWindow_macOS.swift:713-771, 840-864`) with store-side kill + tombstones | port frozen shape; kill goes through DaemonAuthority `killSession` verb instead of `TmuxCLI.kill` | BSTM | S (~150) | structure verbs |
| 16 | **`TmuxCLI` / `TmuxResolver` / `TerminalAppKind` (open-in-system-terminal), wizard's tmux script** | `apps/BentoTermMac/Sources/Services/TmuxCLI.swift` (423), `TmuxResolver.swift` (157), `TerminalAppKind.swift` (91), `AgentWizardWindow.swift` (195) | n/a | **drop** — the daemon owns tmux (bundled binary, resolver, script-building all move behind the `spawn kind:tmux` ensure semantics); `TerminalAppKind` (system Terminal/iTerm fallback) retires with prd-mac-client §5.1's "wizard 落到原生终端" decision. Wizard UI itself is kept, re-targeted at structure verbs | — (deletions) | — | daemon ensure + structure ops |
| 17 | **Menubar MenuContent / Settings / FirstRun / Pairing / Devices windows** | `apps/BentoTermMac/Sources/Views/*` (254/355/692/334/67) | **exists-different** — trunk has A-flavored siblings (`apps/BentoMac/Sources/Views/*`); merge-claims lists FirstRun/MenuContent/Settings as "未逐条读，P6 时 diff 并存对再认领" | keep as B app sources; reconcile against the trunk siblings file-by-file (the P6 claim pass); FirstRun's visible-install path needs #12 | `apps/BentoTermMac` | M (mostly reading/claiming) | #12 for FirstRun |

### 1b. The keystroke-latency / input-coalescing commits — where each lives now

The "4 perf(input) commits" resolve to six commits in `git log`; mapping:

| Commit | What it did | Surface half (in trunk `BentoTerminalPane`?) | Shell/daemon half (owed where?) |
|---|---|---|---|
| `336dfd7` perf(mac-terminal) | draw-on-arrival + IME commit flicker; amortized O(n) history trims | ✅ in trunk (`GhosttyTerminalSurface_macOS.swift`; StateDetection lazy buffering `StateDetectionService.swift:32, 77-95`) | `PaneViewModel._history` slab-trim (`frozen .../PaneViewModel.swift:44-62`) → must be reproduced in TmuxPaneRuntime's byte history |
| `178690d` perf(terminal) | leading-edge input flush in `ControlMode.sendData`; VM parse off main; runtime wakeup coalescing; first-responder guard | ✅ runtime coalescing + responder guard in trunk (`TiledPaneHost_macOS.swift:675-685`) | ⚠️ the Go port **deliberately dropped the 16ms input coalescer** — `daemon/internal/tmuxcm/controlmode.go:113-116` and `types.go:7-10` say "batching belongs to the host layer above". Verify `daemon/internal/host/tmux` implements leading-edge flush + trailing coalescing before calling B's typing path done |
| `4c6e542` perf(input) | output off the keystroke-frozen main thread; IME bypass for plain layouts | ✅ IME bypass in trunk (`GhosttyTerminalSurface_macOS.swift:729-731`) | LocalPty read-queue delivery (frozen-only; relevant only if #12(a)); VM routing dies — the trunk rule becomes: **BentoLink attach-stream bytes must reach `surface.feed()` without a main-thread hop** (feed is `nonisolated`, `TerminalSurface.swift:83-87`, and runs on the surface's ioQueue) — that wiring is TmuxPaneModule's responsibility |
| `f601809` perf(input) | last hop off main: empty-queue fast path %output → surface on parse queue; `feedData` nonisolated under `feedLock` | ✅ protocol + surface halves in trunk (`GhosttyTerminalSurface.swift:519-524`) | fast-path + lock pattern → TmuxPaneRuntime feed path |
| `2301043` / `496e4d7` perf(terminal) | dirty-driven redraw (needsDraw + ~4fps idle blink); parse queue split from draw queue with safe free chain | ✅ both fully in trunk (`GhosttyTerminalSurface_macOS.swift:61, 77, 474-492, 523-536, 569-579`) | — |

Daemon-side output batching (`189c114`, 25ms PTY batches in the relay client)
is in the shared relay lineage — merge-claims records both relay clients as
byte-identical.

## 2. Where it all lands (the shape)

The plan doc's answer is explicit: **shells are per-product**
(docs/tmuxpane-design.md: "外壳按产品注册：BentoMac 注册 acp；BentoTermMac 注册
tmux"; architecture.md lists BentoShellMac as A's shell). So:

### 2.1 New module `modules/BentoShellTermMac`

Product-B's AppKit shell, sibling of BentoShellMac. Dependencies:
`BentoWorkbench`, `BentoTerminalPane`, `BentoTmuxPane`, `BentoUI`,
`BentoFoundation`, `BentoLink` — **not** `BentoAgentPane`. Contents (ports from
§1): `TermWindowManager` + native-tab machinery (#1, #11, #15),
`TermToolbarController` (#2, #3, #8-menu, #10), `WindowSidebar` (#9), tiled-host
wiring + selectors (#5, #6, #7), plain-tab transport if #12(a), theme bridge
(#13).

### 2.2 The shared-chrome problem (palette / dock / voice / notifier / panels)

Trunk BentoShellMac already contains the adapted versions B wants (#14), but
every file in it blanket-imports `BentoAgentPane`, and SPM makes BentoShellMac
→ BentoAgentPane → MarkdownUI a hard edge. Three options:

- **(b) extract `modules/BentoShellChromeMac`** with CommandPalette(+controller),
  PreviewDock, FilePreviewPanel, NewPaneDirectoryPanel, MacVoiceController,
  MacAwaitingNotifier, DividerOverlay (~2.0k lines), imported by both shells.
  Recommended IF the BentoAgentPane imports prove to be boilerplate (unknown —
  not audited symbol-by-symbol; `SessionHistoryPanel` at least is genuinely
  workbench/catalog-coupled and can stay in BentoShellMac).
- (a) link BentoShellMac into BentoTermMac — rejected: drags the ACP pane +
  MarkdownUI into B and violates per-product shells.
- (c) duplicate into BentoShellTermMac — acceptable fallback (~2k lines of
  already-diverged-once code), zero coordination cost with the agents editing
  modules/ today.

Decision owner: H, after a 30-minute symbol audit. Everything else in this doc
works under either (b) or (c).

### 2.3 `apps/BentoTermMac/Sources` keeps

- `App/BentoMenubarApp.swift` — MenuBarExtra + `TerminalCommands` (#4).
- `App/AppDelegate.swift` — daemon lifecycle (switches from frozen
  `desktop-term` CLI to trunk `daemon/` CLI + statekv subscription; drops the
  TmuxCLI polls), appearance, `isTerminating`, `newWindowForTab`.
- `Views/` — MenuContent, Settings, FirstRun, Pairing, Devices, Wizard (#16
  re-target, #17).
- `Services/BentoCLI.swift` — daemon control (reconcile with trunk BentoMac's
  249-line version, which has the update/restart machinery).
- Deleted: `TmuxCLI`, `TmuxResolver`, `TerminalAppKind`, `Models/TmuxSession`.

## 3. Build order

What can compile **before BentoTmuxPane exists**:

1. **Shared-chrome decision + extraction** (§2.2). Pure refactor; A's tests
   (BentoCoreTests) are the regression line. No daemon dependency.
2. **BentoShellTermMac skeleton**: TermWindowManager + native tabs + quit/
   reopen + frame owner + residency/theme (#1, #11, #13, #15-shape) against a
   stubbed session-list source (a `[String]` publisher). Compiles and runs
   showing empty windows.
3. **Toolbar + search-field palette anchoring + Shell menu** (#2, #3, #4)
   against the same stubs; selectors can land on a placeholder host protocol.
4. **Plain-tab transport (#12(a))** if chosen — LocalPty port is standalone
   and gives the skeleton something real to render via BentoTerminalPane.

What gates on **BentoTmuxPane (G) / daemon**:

5. TmuxPaneModule registry hosting in the tiled host (#6) — needs G steps 1-2
   (tmuxpane-design 构建顺序) and daemon steps 3-4 (attach/output + structure
   op + statekv mirror).
6. Window strip / sidebar / dormant switcher fed by the structure mirror
   (#2, #9, #10); ⌘0-9 + find family + newTmuxWindow selectors (#5, #7).
7. Sizing authority (#8) — **last**, because the daemon seam is undesigned;
   ship B-on-trunk v0 with `latest` behavior (daemon default) and the menu
   disabled if necessary.
8. Kill/rename/move verbs through DaemonAuthority (#15) + wizard re-target
   (#16) — daemon structure op.

## 4. Known unknowns (explicitly not verified)

- Real (non-boilerplate) `BentoAgentPane` symbol usage inside BentoShellMac
  chrome files — determines §2.2 (b) vs (c).
- Whether `daemon/internal/host/tmux` (being written now) implements the
  178690d input-flush discipline and output batching — verify before perf
  sign-off; the parser layer explicitly punts it upward.
- Cell-exact (+1 cell) pane fitting inside trunk's fractional
  LayoutTree projection — asserted feasible by tmuxpane-design, unproven.
- Scrollback depth available to ⌘F after cursor'd attach (eventlog retention
  window + `capture-pane -e` ceiling) vs frozen full-history behavior.
- The sizing-policy daemon ops (#8) — no design exists; needs its own
  paragraph in tmux-host-design before H can wire the menu.
- FirstRunWindow (692 lines) was never line-by-line claimed post-merge
  (merge-claims table) — treat its port as read-and-claim, not copy.
