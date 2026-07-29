# Bento Term iOS on trunk + the BentoShelliOS extraction

2026-07-29. Read-only reconnaissance for P7 step 7 ("B iOS 迁栈 — 用户已拍板要出",
docs/tmux-host-design.md 顺序 #7). Two inventories: (1) which of
`apps/BentoIOS/Sources` is generic workspace-shell (→ new module
`modules/BentoShelliOS`) vs A-specific; (2) what the frozen terminal iOS app
(`apps/BentoTermIOS/Sources`) contains, feature by feature, and what its trunk
rebuild links. Transport is BentoLink only — **Citadel/NIOSSH direct-connect
dies and must not be ported.**

Companions: [term-shell-port.md](term-shell-port.md) (Mac; shares the daemon
gates), [tmuxpane-design.md](tmuxpane-design.md),
[tmux-host-design.md](tmux-host-design.md), [prd-bento-term.md](prd-bento-term.md).

## 1. BentoShelliOS extraction inventory (from `apps/BentoIOS/Sources`)

Ground truth first: the two iOS apps are largely the SAME app twice.
`diff` between same-named files (line-diff counts): 0 for
BentoMark/QRScannerView/ActiveSessionsStrip/KeychainService/HapticService/
DebugLogger/LiveActivityService/RelayDaemonStore/BentoActivity; single-digit
for BentoApp/RelayDaemon/RelayPairView/RelayPairingService/SpeechService/
AudioCaptureService/TerminalColorTheme/SessionPickerView. The divergence is
concentrated in SettingsView (357), HostSessionsView (247), SessionManager
(196), VoicePressGesture (173), HostListView (166), VoiceInputController (115).
That is the extraction thesis: pull the shared shell into one module and the
two apps stop drifting.

### 1a. Generic workspace-shell → `modules/BentoShelliOS`

| File | Lines | Notes / seams needed |
|---|---|---|
| `Views/Workspace/WorkspaceScreen.swift` | 738 | Screen scaffolding: top chrome (back / workspace title / Parallel│Focus / ⋯ menus), overlays (voice, compose bar, onboarding, tips, legend), iPad NavigationSplitView + sidebar visibility sync, split/close/kill/move dialogs. No direct agent-type references — talks to `WorkspaceViewModel` + `VoiceInputController` + `FilePreviewPresenter` only |
| `Views/Workspace/PaneContainerVC.swift` | 678 | Tiles/Focus pane container, fractional cell layout, drop-zone + divider overlays (mirrors Mac host). **One A-coupling: `paneControllers: [PaneID: AgentChatVC]` (line 31)** — needs the PaneModule registry (pane → UIViewController factory) to become generic, same seam tmuxpane-design mandates for Mac `makeCell` |
| `Views/Workspace/PaneTabBar.swift` | 220 | Focus-mode bottom pane switcher (compact width) — pane-model generic |
| `Views/Workspace/PaneChrome.swift` | 217 | `PaneTitleBar` (UIKit) + state-dot chrome — generic (PaneState language) |
| `Views/Workspace/FilePreviewPanel.swift` | 244 | `FilePreviewPresenter`: iPhone sheet / iPad trailing dock over BentoFilePreviewKit — generic |
| `Views/Workspace/GestureOnboardingOverlay.swift` | 116 | two-gesture onboarding — generic |
| `Views/Voice/VoiceInputController.swift` | 471 | voice glass / hold-to-talk orchestration over BentoVoiceKit — generic (routes text via runtime `send`/`insertIntoComposer`, which `TmuxPaneRuntime` maps to WritePane±CR) |
| `Views/Voice/VoicePressGesture.swift` | 213 | current (redesigned) press pipeline — generic; **UX differs from frozen term's 4-direction compass — see §2 voice row** |
| `Views/Voice/VoiceOverlayView.swift` | 25 | generic |
| `Views/HostList/HostListView.swift` | 321 | paired-daemon list + pair entry — generic (relay daemons only; exactly what B needs post-SSH) |
| `Views/HostList/RelayPairView.swift` | 355 | QR/6-digit pairing — generic (byte-identical twin exists in term app) |
| `Views/HostList/QRScannerView.swift` | 56 | generic |
| `Views/HostList/WelcomeFlowView.swift` | 311 | onboarding flow — generic scaffold; copy is per-product (merge-claims: B keeps tmux-vocabulary copy in HowBentoWorksView) |
| `Views/HostList/ActiveSessionsStrip.swift` | 7 | stub — generic |
| `Views/Session/HostSessionsView.swift` | 471 | workspace picker + new-session + history rows; generic SHAPE. Seam: `SessionLister` calls `SessionManager.acpStore` (see 1b) — parameterize on a store-provider |
| `Views/Session/AgentSessionWizardView.swift` | 160 | wizard (dir/agent/layout) — near-identical twin in term app (22-line diff); generic with per-product preset catalog |
| `Views/Session/SessionPickerView.swift` | 7 | stub — generic |
| `Views/Settings/SettingsView.swift` | 444 | mixed: appearance/theme/voice/telemetry sections generic; ASR + provider bits A-flavored; split into shared sections + per-app assembly |
| `Views/Common/BentoTheme.swift` | 410 | brand tokens (`BentoBrand`) — generic (48-line drift vs term twin to reconcile) |
| `Views/Common/BentoMark.swift` | 155 | generic |
| `Views/Common/HowBentoWorksView.swift` | 110 | generic scaffold, per-product copy (term copy is the B truth per merge-claims) |
| `Models/RelayDaemon.swift` / `RelayDaemonStore.swift` | 82 / 74 | pairing records — generic |
| `Models/BentoActivity.swift` | 29 | Live Activity attributes — generic |
| `Models/TerminalColorTheme.swift` | 13 | shim over BentoUI ThemeStore — generic |
| `Services/SessionManager.swift` | 300 | attach-slot LRU, scene-phase suspend/resume, Live Activity sync, navigation path — generic EXCEPT the two A lines (1b). Already has the seam: `storeProvider: (Host) -> AgentWorkspaceStore?` (lines 46-47) is injectable |
| `Services/RelayPairingService.swift` | 154 | generic |
| `Services/KeychainService.swift` | 122 | generic |
| `Services/AggregateLiveActivityController.swift` | 102 | generic (state-language driven) |
| `Services/HapticService.swift` / `DebugLogger.swift` | 56 / 53 | generic |
| `Services/{Audio,Speech,LiveActivity}Service.swift` | 2 / 3 / 4 | re-export stubs — generic |
| `App/BentoApp.swift` | 132 | stays per-app (bundle id, deep-link scheme `bento-acp://` vs `bento://`, fonts) but is template-identical (8-line diff) — the helper pieces (`SystemAppearanceSync`) can move |

Extraction total: ~5.6k lines of which ~5.2k move essentially verbatim.

### 1b. A-specific (stays in `apps/BentoIOS` / BentoAgentPane orbit)

| File | Lines | Why |
|---|---|---|
| `Views/Workspace/AgentChatVC.swift` | 367 | hosts `AgentChatView`/`AgentChatModel` (BentoAgentPane) as pane content — the iOS sibling of Mac's `AgentChatSurface`. THE only wholly A-specific view file |
| `Services/SessionManager.swift:250-268` | ~19 | `acpStore(for:)` — `AgentWorkspaceStore.relayStore(...)` + `AcpPaneModule.install(on: store)` (line 265). Moves to the A app's composition root; B's twin installs `TmuxPaneModule` instead |
| Provider connect | 0 | **not present on iOS** — `ConnectProvidersView`/provider catalog have zero references under `apps/BentoIOS/Sources` (grep-verified); provider connect is Mac-only today. Nothing to carve |

## 2. B-iOS feature inventory (from `apps/BentoTermIOS/Sources`)

| Feature | Frozen anchor | Verdict on trunk |
|---|---|---|
| **Hosts list — relay daemons** | `Views/HostList/HostListView.swift:146-154` (daemon rows), `RelayPairView` (355, twin), `RelayPairingService` (153) | KEEP via BentoShelliOS — this is the same pairing UI A uses |
| **Hosts list — SSH direct-connect** | `HostListView.swift` (455; hosts section), `HostEditView.swift` (313), `Models/HostStore.swift` (77), `Services/SSHService.swift` (388, Citadel/NIOSSH + relay branch), `SSHKeyGenerator.swift` (42), `BentoRelayClient.swift` (764, SSH-over-WSS), transport enum `frozen .../Host.swift:11-22` (`.directTCP` / `.relay`) | **DIES. Do not port.** BentoLink sealed streams replace both branches; `.directTCP` has no successor (prd's "接入层" is the paired-daemon path). ~1,650 lines deleted |
| **Session discovery** | `Services/SessionManager.swift:260-337` — short-lived SSH runs `tmux ls` (+ `TmuxParsers.parseTmuxLs`) | replaced by statekv `tmux/<target>/structure` read (same shape as A's `SessionLister.refresh` → `store.syncWithDaemon`, `apps/BentoIOS .../SessionManager.swift:288-299`) |
| **Terminal canvas + gestures** (long-press voice, single-finger scrollback, double-tap keyboard, selection, mouse-reporting scroll forwarding) | surface: trunk-identical `modules/BentoTerminalPane/GhosttyTerminalSurface.swift` (1,211, `#if canImport(UIKit)`) — **already in trunk**. App glue: `Views/Terminal/TerminalContainerVC.swift` (1,750: title bar 1459+, stateTint, `ScrollMarkPager`, accessory hookup, voice forwarding, `PaneViewModel`/`TerminalViewModel` bindings) | surface = reuse trunk. `TerminalContainerVC` ports as the **TmuxPaneModule iOS surface VC**, rebound from the dying VMs to `TmuxPaneRuntime` + BentoLink attach stream (feed must stay off-main — `TerminalSurface.feed` is `nonisolated` for exactly this). Estimate: ~60% survives mechanical rebinding, ~700 lines touched |
| **Tiles/List/Focus + page/viewport** (prd §2.2-2.4: page = tmux truth, three render rules, no pinch) | `Views/Terminal/TerminalWrapperView.swift` (2,491): chrome + sizing UX 733-761, `PaneContainerBridge` 829-833, `PaneContainerVC` 898-end (page/viewport math, tiles, bottom window tabs) | the ACP twins (`WorkspaceScreen` 738 + `PaneContainerVC` 678 + `PaneTabBar` 220) are the SAME code evolved — B reuses them via BentoShelliOS + registry. The tmux-specific residue to port: page-size = window grid (cell-exact, not fractional), window (not pane) tab bar in List, page>viewport two-finger pan. Unknown: how much of prd §2.2's pan/letterbox behavior survived into the ACP container (not line-audited) |
| **Quick-keys toolbar** (floating ↑↓↵Esc Tab + zoom/pane-menu, prd §3.3) | `Views/Terminal/FloatingQuickKeysToolbar.swift` (607; keys 51-57, glass capsule, reserved band) | port as-is into the B app (or BentoTmuxPane iOS): depends only on `AccessoryKey` + `BentoBrand`. A has no equivalent (chat composer instead) |
| **Keyboard accessory bar** (Esc/Tab/Ctrl-sticky/arrows/`|` `/` `~` `-`, prd §5.3) | `Views/Terminal/KeyboardAccessoryView.swift` (161; defines `AccessoryKey`) | port as-is, B-only |
| **Size-authority UX** (prd §2.5 three policies: 跟随活动设备 `latest` / 适配所有设备 `smallest` / 以此设备为准 `manual`+owner; menu shows "set by \<device\>"; strict resize whitelist §2.6) | menu `TerminalWrapperView.swift:733-761`; propagation 360-361, 852-877, 959-960; policy TYPE `TerminalSizingMode.swift` (trunk-identical); ENFORCEMENT was client-side in frozen `TerminalViewModel+Structure.swift:622-770` (adopt-only-read, `@bento_size_owner`, `%client-detached` release) | UI ports small; **the state machine has no home yet** — tmux-host-design defines only a `resize` op; tmuxpane-design says the three-policy seam is daemon-side and the client "只发意图". Same undesigned-seam flag as the Mac doc (§1 #8 there). B iOS v0 can ship read-only "latest" behavior; the menu gates on the daemon seam |
| **Handoff / cross-device continuation** | no dedicated code (grep: zero "handoff" hits) — it IS tmux persistence + sizing authority + reattach | free once attach/catch-up + sizing exist; scrollback catch-up is the daemon's sequenced-eventlog + `capture-pane` fallback |
| **Three-state machine → List colors / title dots / Live Activity** (prd §2.8, §3.4) | detection: trunk-identical `AgentRulePresets`/`AgentStatusRules`/`StateDetectionService` (already in `modules/BentoTerminalPane`); consumption: `AggregateLiveActivityController` (102, twin), title bars, wrapper chrome | reuse trunk detection; feed it from the attach stream in `TmuxPaneRuntime` (this is the "PaneState 90/525 分歧" answer in tmuxpane-design — state 'how do we know' sinks into the pane backend) |
| **File preview / path tap** | `Views/Terminal/PathPreviewUI.swift` (338), `Services/FilePreviewSources.swift` (223, SSH-exec + relay sources) | drop the SSH source; trunk `BentoFilePreviewKit` + the daemon `bento-file` op (already built for A iOS) replace it. Path DETECTION is already in trunk (`PathDetection.swift`, `SurfacePathHitEngine`); the term-era surface→preview opening was deliberately re-cut as callbacks in the trunk surface port |
| **Voice** | `Views/Voice/*` (470/15/158) — frozen 4-direction compass incl. left/right = LLM→shell transform | adopt the ACP-era redesigned pipeline via BentoShelliOS (VoicePressGesture diverged 173 lines since). ⚠️ product delta: frozen B shipped the WeChat-style 4-direction + LLM-to-shell; hybrid-workbench-design says "不复活 shell 的 LLM 命令转换层". Deviating from frozen UX **requires user confirmation** (merge-claims discipline) — flag, don't decide here |
| **Onboarding / gestures overlay** | `Views/Terminal/GestureOnboardingOverlay.swift` (116, twin of A's) | reuse via BentoShelliOS |
| **Live Activity + haptics + debug log + keychain** | twins, 0-9 line diffs | reuse via BentoShelliOS |
| **Settings** | `Views/Settings/SettingsView.swift` (536; fonts/themes/keys sections) | shared sections from BentoShelliOS + B-only terminal sections (font size = page pixel size, theme picker already trunk-`ThemeStore`-backed incl. `.itermcolors` import) |

## 3. Proposed target composition: `apps/BentoTermIOS` on trunk

**Links (SPM products):** `BentoShelliOS` (new), `BentoWorkbench`,
`BentoTerminalPane`, `BentoTmuxPane` (new, from G), `BentoLink`/`ACPHostKit`,
`BentoVoiceKit`, `BentoFilePreviewKit`, `BentoUI`, `BentoFoundation`.
**Not linked:** `BentoAgentPane` (no chat stack in B), and the retired
`SwiftTerm` / `Citadel` / `SwiftTmux` / `BentoTerminalCore` package deps
(project.yml:20-29, 139-143 all go).

**Remains as app sources (~1.5-2k lines):**
- App entry (`BentoApp` twin: bundle id `com.bento.app`, `bento://` deep links,
  bundled fonts), Info.plist keys (project.yml:144-160 mostly unchanged).
- `FloatingQuickKeysToolbar` + `KeyboardAccessoryView` (768).
- B-only Settings sections; term-copy onboarding text (HowBentoWorks).
- Composition root: `TmuxPaneModule.install(on: store)` + tmux store provider
  (the twin of `SessionManager.acpStore`, `apps/BentoIOS .../SessionManager.swift:250-268`).

**Net-new (estimates):**
- TmuxPaneModule iOS surface VC (TerminalContainerVC rebind): ~700 touched /
  ~400 genuinely new.
- PaneContainerVC registry seam + window-vs-pane tab bar variant: ~150.
- Cell-exact page sizing + two-finger pan restoration in the shared container
  (if absent — see unknown above): ~200-400.
- Sizing-intent UI wiring once the daemon seam exists: ~100.
- BentoShelliOS extraction itself (mechanical moves + the two seams): days,
  not weeks; it is the same split BentoShellMac already proved on Mac.

**Gates:**
1. Daemon tmux host steps 3-5 (attach/%output→log→stdio, structure op +
   statekv mirror, resize + credit + capture-pane) — tmux-host-design 顺序.
2. BentoTmuxPane (G steps 1-3) — `TmuxPaneRuntime`, `DaemonAuthority`,
   PaneModule registry ("makeCell 走注册表" — the same registry unlocks
   `PaneContainerVC` here).
3. BentoShelliOS extraction (this doc §1) — can start NOW, gated on nothing;
   A's iOS app is the regression harness.
4. Sizing-authority daemon seam — undesigned; last.
5. Per merge-claims discipline: voice-UX delta and any onboarding copy changes
   need user sign-off before landing.

## 4. Honest unknowns

- Whether the ACP `PaneContainerVC` retained prd §2.2's page>viewport
  two-finger pan and page<viewport letterboxing, or simplified to
  fit-to-viewport (fractional panes made it moot for A) — needs a line audit
  before estimating the "cell-exact page" work precisely.
- `WorkspaceScreen`'s ⋯ menus vs the frozen `TerminalWrapperView`'s (window
  list, "适配到当前设备" action): not diffed item-by-item here; the term ⋯ menu
  content should be claimed the way merge-claims does Mac menus.
- Live Activity deep-link scheme collision (`bento://` vs `bento-acp://`) once
  both apps share `BentoActivity` — trivial but easy to forget.
- How `TmuxPaneRuntime` surfaces per-PANE state to `SessionManager`'s
  aggregate Live Activity (A aggregates via workspace store publishes; the
  mapping exists on paper in tmuxpane-design only).
- Whether `BentoShelliOS` should also absorb the iPad sidebar bits that today
  live in `modules/BentoWorkbench/PaneSidebar.swift` (shared with Mac) — left
  alone here; B's Focus sidebar rows are WINDOWS (see Mac doc §1 #9) and the
  iPad variant should follow whatever shape H lands for Mac.
