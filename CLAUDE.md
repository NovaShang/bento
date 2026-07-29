# Bento (ACP-native)

Multi-device UI for **parallel ACP coding agents**. A Go daemon on the Mac hosts
the agent processes; the shared Swift package `BentoCore` owns the workspace +
chat; macOS/iOS apps are thin shells; a Cloudflare relay gives paired iOS
devices an E2E-encrypted pipe. Full map: **`docs/architecture.md`** (read it
before touching architecture).

## Building & running the macOS client ("Bento ACP")

**Use the one-shot script — don't reinvent the xcodebuild invocation:**

```sh
scripts/mac-dev.sh            # rebuild BentoCore/app + hot-swap the running GUI
scripts/mac-dev.sh build      # rebuild only
scripts/mac-dev.sh relaunch   # quit GUI + relaunch the last build
scripts/mac-dev.sh install    # rebuild + Developer-ID sign + install to /Applications
scripts/mac-dev.sh status     # GUI + daemon + last-build state
```

The default (`rebuild`) builds Release, ad-hoc signed, to
`build/Build/Products/Release/Bento ACP.app` and relaunches from there **without
touching the `/Applications` install** — the everyday loop for seeing a
`BentoCore`/`BentoMenubar` change in the real app. Use `install` when you want
the installed app itself updated (preserves code identity/TCC via Developer ID).

What the script encodes, so you don't re-derive it:
- Target/scheme is **`BentoMenubar`** (product name "Bento ACP", bundle id
  `com.bento.menubar.acp`). The iOS scheme is `Bento`.
- The app's "Embed Go binaries" build phase runs `make build` in `daemon/`, so
  **`go` + Homebrew must be on PATH** (the script adds `/opt/homebrew/bin`).
- `pbxproj` is xcodegen-generated: edit `project.yml` + `xcodegen generate`
  (Xcode closed), never hand-edit the pbxproj.

### ⚠️ The one rule: NEVER kill or restart `bento-daemon`

The daemon (launchd job `com.novashang.bento.acp.daemon`, PPID 1) **hosts the
ACP agent processes — including the agent that may be running your commands.**
It outlives the GUI by design; restarting it kills every live agent
conversation (i.e. you kill yourself). Restarting the *GUI* is always safe — the
daemon keeps agents alive and the relaunched GUI reattaches to their sessions.
`mac-dev.sh` only ever signals the GUI Mach-O
(`…/Bento ACP.app/Contents/MacOS/Bento ACP`), which can't match `bento-daemon`
or the `bento` CLI. If you must signal processes by hand, match that exact path —
never a bare `pkill bento`.

## Tests

ACP product (trunk):
- Swift modules (all of them): `swift test` at the repo root (package `BentoModules`, sources in `modules/`, tests in `tests/`)
- `daemon`: `cd daemon && go test ./...`
- iOS sim loop: `scripts/ios-dev.sh` (see its header)

Bento Term (frozen terminal product, same repo):
- frozen packages: `swift test` in `frozen/bento-terminal-core` and `frozen/swift-tmux`
  (live tmux suites need a real tmux) · `cd frozen/desktop-term && go test ./...`
- apps: xcodebuild schemes `BentoTerm` (iOS) / `BentoTermMenubar` (macOS)

## Working style

Forward-only git: never `reset`/`--amend`; the bar is "it compiles", then commit
(one logical change per commit). End commit messages with the
`Co-Authored-By: Claude …` trailer.
