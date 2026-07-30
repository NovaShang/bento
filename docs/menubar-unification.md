# Menubar unification

2026-07-30. Two products ship two `LSUIElement` Mac apps, and both draw a
status item for **the same host**. This document is the design for collapsing
that into one menu-bar presence, the constraint that forces the shape, and the
staged plan for getting there without a user-visible change until the product
decisions are made.

Status: **stage 1 done** (this doc, `BentoMenuKit`, URL schemes). Stages 2–4
are blocked on the three open questions in §7 — do not start them from this
document alone.

## 1. The problem

- **Bento ACP** — `apps/BentoMac`, bundle id `com.bento.menubar.acp`, product
  name "Bento ACP". Menubar app, `MenuBarExtra`, its own status item.
- **Bento Term** — `apps/BentoTermMac`, bundle id `com.bento.menubar`, product
  name "Bento". Menubar app, `MenuBarExtra`, its own status item.

Install both and the menu bar shows two Bento icons. Open either one and most
of what's inside is *the same information about the same process*: is
`bento-daemon` up, which daemon id, is the relay connected, how many devices
are paired, pair a new one, manage paired devices, stop the service, quit.
The daemon is singular (one launchd job, one `~/.bento-acp`, one socket), so
the second icon is not a second thing — it is a second window onto one thing.

## 2. The constraint that forces the shape

**macOS allows exactly one process per `NSStatusItem`.** A status item is
vended to the process that creates it; there is no API for two apps to share
one item, no way for app A to add items to app B's menu, and no supported way
to draw into another process's status item. `MenuBarExtra` is the SwiftUI
wrapper over the same object, with the same rule.

So "one icon in the menu bar" and "two independently launchable product apps"
can only both be true if the icon belongs to a **third process** that is
neither product — a small resident agent that owns the status item, reads the
host's state, and launches or activates the products.

## 3. Host-scoped vs product-scoped

The load-bearing insight: almost everything in today's two menus is
**host-scoped** — it describes or controls `bento-daemon`, which is one
process shared by both products. Only a thin layer is **product-scoped**.

| Concern | Scope | Why |
| --- | --- | --- |
| Daemon up/down, daemon id, uptime | host | One daemon, one answer |
| Start / stop the background service | host | One launchd job |
| Engine (daemon binary) update detected | host | The binary is shared; the skew is the host's |
| Engine restart + its cost ("ends N agents") | host | Kills agents from *both* products |
| Relay endpoint + relay connected | host | One relay connection per daemon |
| Pair a new device | host | Pairing is the identity layer, per-daemon |
| Paired devices / revoke | host | Same key store, same daemon |
| Session / agent inventory (counts) | host | The daemon owns the processes |
| Telemetry opt-in | host | One installation-level consent |
| Voice / ASR keys, API keys | host | One credential store per machine |
| Quit | ambiguous | Today "quit this app"; after unification "quit which?" — see §7 |
| Open a workspace / session by name | product | Only that product can render it |
| New agent workspace / new tmux session | product | Product-specific creation flow |
| Theme, appearance mode, pane behaviour | product | Different UIs, different settings |
| Getting-started guide | product | Product-specific onboarding |
| Command palette, splits, find | product | Window-level, not menubar |

The rendered *presentation* of a host-scoped row may still differ per product
today (Bento Term shows "Stop background service", Bento ACP does not; Bento
ACP shows the engine-update prompt, Bento Term does not). That is a product
decision, not a scope decision — the shared code parameterizes it.

## 4. The recommended design: `BentoMenu.app`

A third, tiny app.

```
┌ BentoMenu.app (LSUIElement, no windows except its own popovers) ┐
│  • owns THE status item — the only Bento icon in the menu bar   │
│  • reads bento-daemon over the same IPC the CLI uses            │
│  • renders host-scoped rows itself (BentoMenuKit)               │
│  • launches / activates the products by URL scheme              │
└──────────────┬──────────────────────────────┬───────────────────┘
        bento-acp://…                   bento-term://…
               ▼                              ▼
      ┌ Bento ACP.app ┐              ┌ Bento.app (Term) ┐
      │ window-only   │              │ window-only      │
      │ no status item│              │ no status item   │
      └───────────────┘              └──────────────────┘
                       ▲          ▲
                       └── bento-daemon (one, shared) ──┘
```

Reference shapes that already work this way: **JetBrains Toolbox** (one
resident agent, N installed IDEs it launches), **Adobe Creative Cloud** (a
menubar agent that owns updates and account state for every CC app),
**Steam** (`steam://run/<appid>` — a URL scheme as the launch ABI between a
resident process and the thing it starts).

### 4.1 Mechanics

**Launch / activate by URL scheme.** `BentoMenu.app` never links the product
apps and never `exec`s their binaries; it calls
`NSWorkspace.open(URL(string: "bento-acp://workspace/api-refactor")!)`.
Launch Services finds the installed app by its registered scheme, launches it
if it is not running, and delivers the URL to
`application(_:open:)` if it is. This gives us, for free: works whether or
not the app is running; works when the app lives anywhere in `/Applications`;
degrades to "nothing happened" when the product is not installed (no crash,
no stale absolute path); and is scriptable/testable from the shell with
`open bento-acp://workspace/foo`.

Surface (stage 1 ships the parsing + handling for these):

| URL | Effect |
| --- | --- |
| `bento-acp://` , `bento-acp://open` | Launch/activate Bento ACP, open or focus its window |
| `bento-acp://workspace/<name>` | Focus that workspace, opening the window if needed |
| `bento-term://` , `bento-term://open` | Launch/activate Bento Term, open or focus its window |
| `bento-term://session/<name>` | Focus/attach that tmux session |

Names are percent-decoded. Anything else — unknown host, empty name, wrong
scheme — is a **no-op**, never a crash: an untrusted string arriving from
`open(1)` or another app must not be able to do anything but the two things
above.

**Residency.** `BentoMenu.app` is registered as a login item with
`SMAppService.mainApp` (the same API `LoginItem` already wraps in both app
delegates), and marked `LSUIElement` so it has no Dock icon and no
`applicationShouldTerminateAfterLastWindowClosed` problem. It is *not* a
launchd daemon: it is a UI process and must die with the user session.
It ships inside whichever product installs first (see §7, open question 1)
and is registered idempotently — registering an already-registered main app
is a no-op.

**The daemon still ships with the host, not with the menu.** `BentoMenu.app`
reads the daemon; it does not own it. The embedded `bento` + `bento-daemon`
helpers stay where they are (each product's `Contents/MacOS/helpers/`), and
the engine-update check keeps comparing *the daemon binary this app would
launch* against *the one the running daemon executes*. When the menu app is
the thing that offers the restart, it must offer the restart of the daemon
that the daemon's own `exe_path` names — not blindly its own copy.

**Settings split.** Host-scoped settings (relay URL, telemetry opt-in, voice
provider + API keys, login item) move into `BentoMenu.app`'s own Settings
scene and are stored under a shared suite (`UserDefaults(suiteName:)` in an
App Group, or the daemon's `config.json` where the daemon already reads it).
Product-scoped settings (appearance mode, pane behaviour, terminal font)
stay in each product's Settings, reachable from the product's own window
menu. The menu app's Settings row therefore shows *host* settings; a
"Bento ACP settings…" / "Bento Term settings…" row routes into the product
via the URL scheme.

**Version skew.** Two products can ship two different `BentoMenu.app`
versions. Resolution rule: the newest wins — on launch, each product compares
its bundled `BentoMenu.app` `CFBundleVersion` against the installed one and
replaces it only if strictly newer, then re-registers the login item. The
menu app itself must therefore tolerate talking to an older daemon (it
already must: every field added to the daemon's status is optional and a
missing field reads as "too old to say", never as a decode failure).

**Uninstall.** Removing one product must not leave an orphan icon that opens
nothing. `BentoMenu.app` resolves each product at render time
(`NSWorkspace.urlForApplication(toOpen:)` on its scheme); a product with no
handler is *hidden* from the menu, not shown-and-broken. When neither product
resolves, the menu app unregisters its login item and quits — the last one out
turns off the light.

### 4.2 What each menu contains after unification

Sketch only — the exact list is open question 2.

```
▾ (one Bento icon)
   Connected · 2 devices                 ← host
   daemon a1b2c3d4…                      ← host
   Update ready · restart engine         ← host, when skewed
   ──
   Bento ACP        ▸  [workspaces…]     ← product A, via bento-acp://
   Bento Term       ▸  [tmux sessions…]  ← product B, via bento-term://
   ──
   Pair new iPhone…                      ← host
   Paired devices…                       ← host
   ──
   Settings…                             ← host settings
   Quit Bento                            ← see §7 open question 2
```

## 5. Rejected alternatives

**(a) Merge the two products into one app.** One binary, one icon, a mode
switch inside. Rejected: it forces libghostty (and the whole tmux stack) into
the agent-only product, which the module graph deliberately forbids
(`BentoCore` must never depend on `BentoTerminalPane`); it doubles the
download for every user who wants one product; and it makes the term shell —
a verbatim port of a frozen product whose UI must stay byte-faithful —
share a window chrome with a UI that is allowed to change. The two products
have different audiences and different release cadences; a shared *host* is
the thing they have in common, not a shared *app*.

**(b) First launcher wins the status item.** Both apps keep their
`MenuBarExtra` but coordinate at runtime — whichever launches first claims the
item, the second detects it (distributed notification / shared lock) and
stays quiet, rendering the other product's rows into the first one's menu by
IPC. Rejected: there is no way to render across processes, so the "quiet" app
can only send data, not views; the icon's identity flickers with launch order;
quitting the winner silently kills the menu for the loser; and the whole thing
is a bespoke election protocol whose failure mode (both claim, or neither) is
invisible until a user reports two icons again. This is the pattern
`BentoMenu.app` exists to avoid — a third process makes the winner *static*.

**(c) The daemon draws the icon.** `bento-daemon` already outlives every GUI
and already knows all the host-scoped state; let it own the status item.
Rejected on a hard constraint: **the daemon must stay headless.** It is a Go
process that must build and run on Linux (that is the whole point of the
host/client split), and an `NSStatusItem` would make AppKit — hence macOS —
a build dependency of the host. It would also need to run in a GUI session
with a window server connection, which a LaunchDaemon (or a headless Linux
box) does not have. The daemon reports; something with a window server draws.

**(d) Do nothing.** Two icons is a small papercut for the small set of users
with both products installed. Rejected only in the sense that this document
exists — but note that stages 2–4 should not ship until the questions in §7
are answered; a half-unified menu bar is worse than two honest icons.

## 6. Staged plan

**Stage 1 — invisible groundwork. DONE (2026-07-30).**
Zero user-visible change. This document; `modules/BentoMenuKit` holding the
host-scoped menu pieces both apps duplicate (daemon status rows, start/stop
service, engine-update prompt + restart-cost confirmation, pairing and paired
devices rows, settings and quit rows, the `DaemonStatus` model, the `BentoCLI`
process wrapper, the relative-activity formatter) with per-app presentation
parameterized so both menus render exactly what they rendered before; and the
`bento-acp` / `bento-term` URL schemes registered and handled, with a pure
`URL → route` parser under test.

**Stage 2 — `BentoMenu.app` alongside.** Build the third app, `LSUIElement`,
linking `BentoMenuKit`. It renders the host-scoped rows and routes to the
products by URL. Ship it *disabled by default* behind a defaults flag so it
can be exercised without changing anyone's menu bar. Both products still draw
their own icons at this point. Requires: open question 3 (icon identity).

**Stage 3 — the products become window-only.** Remove `MenuBarExtra` from
both Mac apps; drop `LSUIElement`; let `applicationShouldTerminateAfterLast‑
WindowClosed` return true so each product quits with its last window. Move
host-scoped Settings into `BentoMenu.app`; keep product settings in the
product. `BentoMenu.app` becomes the only resident piece and the only icon.
Requires: open questions 1 and 2.

**Stage 4 — distribution and cleanup.** Whichever install path is chosen in
open question 1 (bundled-in-both with newest-wins, or a separate
`bento-menu` cask), plus uninstall handling, version-skew handling, and
migration for users who have both apps as login items today.

## 7. Open questions (product decisions — not mine to make)

1. **Distribution model.** Does `BentoMenu.app` ship *inside* both product
   bundles (installed to `~/Library/Application Support/Bento/` on first
   launch, newest-wins), or as its own artifact (its own cask / its own
   download) that the products merely require? Bundled is invisible and
   always-present but needs the skew rule; separate is honest but adds an
   install step and a way to end up with a menu and no products.

2. **What the merged menu actually is.** The §4.2 sketch is a guess. Real
   questions inside it: do product sessions appear as submenus in the one
   menu, or does the menu just launch the product and let it show its own
   list? Does "Quit" quit the menu app, the products, or offer both? Does
   "Stop background service" stay (it exists in Bento Term's menu today and
   not in Bento ACP's)? Is there still a per-product "Open …" row when the
   product isn't running?

3. **Icon identity.** One icon for a "Bento" that is now a family rather than
   an app. Does it stay `docs/bento-icon-menubar.svg` (today's Bento ACP
   mark), get a family mark, or badge itself with which products are running?
   This is also a naming question: the menu says "Quit Bento" in both apps
   today, and after unification "Bento" means the family.

## 8. Where the code is

- `modules/BentoMenuKit/` — host-scoped menu pieces, the daemon IPC model and
  CLI wrapper, and the URL router. macOS-only; may depend on
  `BentoFoundation` (and, if ever needed, `BentoUI` / `BentoWorkbench` /
  `BentoLink`) but **never** on a pane or a product shell (`BentoAgentPane`,
  `BentoTmuxPane`, `BentoShellMac`, `BentoShellTermMac`) — it is host-scoped
  by construction, and the dependency arrow is the thing that keeps it so.
- `tests/BentoMenuKitTests/` — the URL router and the host-scoped presentation
  strings.
- `apps/BentoMac/Sources/Views/MenuContent.swift`,
  `apps/BentoTermMac/Sources/Views/MenuContent.swift` — each product's menu
  *composition*: the order of rows, and every product-scoped row. These stay
  per-app on purpose. Bento Term's is bound by the fidelity rule
  (`docs/term-shell-port.md`): its wording and layout must not drift.
