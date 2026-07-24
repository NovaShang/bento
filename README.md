# Bento — run a team of AI coding agents

English | [简体中文](README_CN.md)

Run several coding agents in parallel on your own Mac. See who needs you at a glance. Answer with your voice — from anywhere.

<!-- hero: drop a screenshot or short GIF here before publishing.
     Suggested shot: a Parallel window with 4 agent panes in mixed states
     (working / waiting / done), sidebar visible, voice overlay active.
<p align="center"><img src="docs/hero-mac.png" width="720" alt="Bento running four agents in parallel"></p>
-->

Modern coding is several agents working at once while you review, unblock, and decide. Bento is a native macOS workspace built for exactly this — a bento box of agent panes — with an iOS companion so your agent team follows you out the door.

Agents connect through [ACP](https://agentclientprotocol.com) (the Agent Client Protocol), so every pane is a first-class conversation: streaming markdown, tool cards with real diffs, permission prompts as buttons — not a scraped terminal screen.

## An agent team, at a glance

- **Every pane knows its agent's state** — working (blue), waiting for you (amber), done (green ✓), or idle — as a consistent color-and-glyph language on pane title bars, the sidebar, and the session tabs.
- **Agents speak for themselves.** State comes from the protocol's turn lifecycle (a prompt in flight, a pending permission), not from screen heuristics.
- **Any ACP agent works:** Claude Code, Codex, Gemini CLI, OpenCode, Cursor Agent, Copilot CLI, Amp, OpenClaw, Hermes, Antigravity — plus Kimi, GLM, and DeepSeek with your own API key, or any custom command that speaks ACP.
- **Two readings of the same workspace:** Parallel (every pane tiled) and Focus (one conversation full-size, the rest listed). Toggling is a pure view preference — nothing is restructured or lost.

## Real conversations, not scraped screens

- **Streaming transcript** with markdown, collapsible reasoning, and tool-call cards that show live status and unified diffs.
- **Permissions as buttons** — approve an edit with ⌘⏎ after reading the actual diff, answer an agent's question from a proper option list.
- **Slash commands, model/mode switching, usage meters, image attachments** — whatever the agent advertises, the composer exposes.
- **File previews:** click any path in a tool card for syntax-highlighted code or rendered Markdown in the side dock; ⌘P opens a command palette with file search and history.

## Speak instead of type

- **Hold and speak, anywhere in the workspace.** Release to drop the transcript into the composer; slide up to send on the spot. Right-click-hold a pane (two-finger press on iOS) to speak directly to that agent.
- **Recognition that knows the conversation.** Vocabulary is biased by the transcript on screen, and mixed Chinese/English input just works.
- **Zero configuration.** Voice works out of the box through the Bento relay. Bring your own API keys if you prefer direct calls — Apple on-device, OpenAI, and Qwen engines are all supported.

## Sessions that outlive everything

- **Agents live in the daemon, not the app.** Quit the Mac app; your agents keep working. Reopen and the conversation resumes exactly where it was.
- **Pick up any past conversation.** The history catalog remembers every session; reopening respawns the agent and reloads the full transcript.
- **iOS companion:** scan-to-pair, end-to-end encrypted, no accounts. Close the laptop mid-run and answer your agent from your pocket — the workspace structure syncs both ways.

## Install

**Requirements:** macOS 14+ on Apple Silicon.

1. Download `Bento-macos-arm64.zip` from the [latest release](https://github.com/NovaShang/bento/releases/latest).
2. Unzip and drag `Bento.app` into `/Applications`. The app is signed and notarized — it opens without warnings.
3. First run walks you through creating your first agent session, including one-command installers for any agent you don't have yet.

The Mac app is fully self-contained (it embeds the daemon and CLI). The standalone `bento` CLI + daemon (`brew install NovaShang/bento/bento-terminal`) are only needed for headless hosts.

## Privacy

- **No accounts.** Nothing to sign up for; pairing is the only identity.
- **Telemetry is off by default** and strictly opt-in — a closed set of feature counters, no conversation content, ever.
- **Voice audio** goes to the speech provider through the Bento relay (keys live server-side); with your own key it goes directly to the provider. Conversations never leave your machines except through the end-to-end-encrypted relay to your own paired devices.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full picture. The short version:

```
┌─ iOS app ──────┐        ┌─ Cloudflare relay ─┐        ┌─ Mac ────────────────────────────┐
│ WorkspaceScreen │◄─wss──►│  (pairing + E2E-   │◄─wss──►│ bento-daemon                     │
│ chat panes      │        │   encrypted pipe)  │        │  ├─ agent processes (ACP, stdio) │
│ voice           │        └────────────────────┘        │  ├─ statekv (workspace mirror)   │
└─────────────────┘                                      │  └─ unix socket ─── Mac app/CLI  │
                                                         └──────────────────────────────────┘
```

- **`AgentWorkspaceStore`** (in `bento-core`) is the single source of truth: sessions ⊃ panes, one layout tree per session, one agent runtime per pane. Structure syncs to the daemon's statekv (per-session keys, rev-guarded) so every device converges.
- **`AgentSessionViewModel`** is one ACP conversation: a pure state machine over `session/update` notifications, unit-tested without a live connection.
- **The daemon owns the agent processes.** Clients attach and detach; a phone and a Mac can co-view the same agent.

| Layer | Choice |
|---|---|
| Agent protocol | [ACP](https://agentclientprotocol.com) over stdio, via our own [`acpkit`](acpkit/) Swift package (protocol + daemon-client transports) |
| Apps | Native Swift end to end — AppKit/SwiftUI on macOS, UIKit/SwiftUI on iOS — as thin shells over the shared [`bento-core`](bento-core/) package |
| Persistence | Go daemon hosts agents + a small statekv; conversations persist in each agent's own storage (resumed via `session/load`) |
| Remote reachability | Go daemon + Cloudflare Worker relay: pairing, end-to-end-encrypted transport, ASR/LLM proxying — see [docs/relay-protocol.md](docs/relay-protocol.md) |
| Voice | A `SpeechEngine` abstraction over Apple on-device, OpenAI, and Qwen realtime ASR, with transcript-context vocabulary biasing |

## Repository layout

| Directory | What it is |
|---|---|
| `Bento/` | iOS / iPadOS app |
| `BentoMenubar/` | macOS app (menu bar + workspace window) |
| `bento-core/` | Shared Swift core: workspace model, agent sessions, chat UI, voice, file preview |
| `acpkit/` | ACP protocol + daemon-transport Swift package |
| `desktop/` | Go host-side daemon + `bento` CLI (agent hosting, pairing, relay client) |
| `relay/` | Cloudflare Worker relay (pairing, transport, ASR/LLM proxy) |
| `docs/` | [Architecture](docs/architecture.md), PRD, design docs, [relay protocol](docs/relay-protocol.md) |

## Building from source

You need Xcode 16+ and Go 1.23+ (the Mac app embeds the Go daemon at build time).

```sh
git clone https://github.com/NovaShang/bento.git && cd bento
xcodebuild -project Bento.xcodeproj -scheme BentoMenubar -configuration Release build
```

The `BentoMenubar` scheme is the macOS app; the `Bento` scheme is iOS. If you change `project.yml`, regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## License

[Apache-2.0](LICENSE)
