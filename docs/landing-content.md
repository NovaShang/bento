# Bento Landing Page — Content Blueprint

Target: `bentoai.dev`. Single page, English (a `/cn` mirror can reuse
the structure with README_CN.md's voice). Every media slot is specified but
left empty — see the Asset Production List at the bottom.

**Goals, in order:**
1. Download for Mac (primary CTA, repeated 3×: hero / after pillar 4 / final)
2. iOS waitlist email (secondary CTA, one placement — inside the continuity pillar)
3. GitHub star (nav, passive)

**Tone:** the README's voice — confident, concrete, zero hype-words ("AI-powered",
"revolutionary" are banned). Every claim on the page is true today.

**Design language:** clean modern GUI — this is not a terminal and the site must
not cosplay one. Palette derives from `docs/bento-icon.svg` (no purple).
Monospace only where it is literally true: commands, paths, the brew line.

---

## 0. Meta / SEO

- `<title>`: Bento — run a team of AI coding agents
- Description: Run several coding agents in parallel on your own Mac. See who
  needs you at a glance. Answer with your voice — from anywhere. Free & open
  source, for macOS.
- OG image: `[ASSET-og]`

## 1. Nav

Logo (bento-icon.svg) · GitHub (with star count) · Changelog (→ releases) ·
**Download** (button, right-aligned)

## 2. Hero

**H1:** Run a team of AI coding agents

**Sub:** Claude Code, Codex, Gemini and more — side by side in one native Mac
workspace. See who needs you at a glance. Answer with your voice — from
anywhere.

**CTA row:**
- `[Download for Mac]` → `bentoai.dev/mac` (redirects to
  https://github.com/NovaShang/bento/releases/latest/download/Bento-macos-arm64.zip)
- caption under button: Free & open source · macOS 14+ · Apple Silicon
- text link: `View on GitHub →`

**Media:** `[ASSET-hero]` — the product IS the pitch; this slot carries the page.

## 3. Trust strip

One quiet line, monochrome:

> Open source (Apache-2.0) · Native Swift, not Electron · Signed & notarized ·
> No accounts · Built on ACP — works with Claude Code, Codex, Gemini CLI + 10 more

## 4. Problem (3 sentences, no header image)

**H2:** Five agents. One of them needs you. Which one?

Coding now means supervising agents that work in parallel — while you review,
unblock, and decide. The tools we run them in weren't built for that job:
every terminal tab looks identical, an IDE window holds one conversation, and
an agent that hits a permission prompt waits silently until you happen to
check. Bento was built from scratch for exactly this.

## 5. Pillar 1 — states (kicker: YOUR AGENT TEAM)

**H2:** See who needs you — at a glance

Every pane knows its agent's state — **working** (blue), **waiting for you**
(amber), **done** (green ✓), or idle — as one color-and-glyph language on pane
title bars, in the sidebar, and on the session tabs. States come from the
agent protocol itself (a prompt in flight, a pending permission), not from
screen heuristics: agents speak for themselves.

Bullets:
- **Ten agents out of the box** — Claude Code, Codex, Gemini CLI, OpenCode,
  Cursor Agent, Copilot CLI, Amp, OpenClaw, Hermes, Antigravity — plus Kimi,
  GLM, and DeepSeek with your own API key, plus any custom command that
  speaks ACP.
- **Parallel and Focus** — every pane tiled, or one conversation full-size with
  the rest listed. Toggling is a pure view preference; nothing is restructured
  or lost.
- **Drag panes like an IDE** — split, dock, and swap with drop zones; move
  panes across workspaces.

**Media:** `[ASSET-states]`

## 6. Pillar 2 — conversations (kicker: FIRST-CLASS CONVERSATIONS)

**H2:** Real conversations, not scraped screens

Agents connect over ACP — the open Agent Client Protocol — so every pane is a
real conversation: streaming markdown, collapsible reasoning, and tool cards
with live status and actual diffs. Not a terminal emulator squinting at
characters.

Bullets:
- **Permissions as buttons.** Read the real diff, approve with ⌘⏎, answer an
  agent's question from a proper option list.
- **The composer exposes whatever the agent advertises** — slash commands,
  model and mode switching, usage meters, image attachments.
- **Click any file path** in a tool card for a syntax-highlighted preview or
  rendered Markdown in the side dock.

**Media:** `[ASSET-conversation]`

## 7. Pillar 3 — voice (kicker: VOICE INPUT)

**H2:** Speak instead of type

Hold and speak, anywhere in the workspace. Release to drop the transcript into
the composer — or slide up to send it on the spot. Right-click-hold any pane
to speak directly to that agent.

Bullets:
- **Knows your conversation.** Recognition is biased by the transcript on
  screen; mixed Chinese/English just works.
- **Zero configuration.** Works out of the box through the Bento relay. Bring
  your own API keys for direct calls if you prefer — Apple on-device, OpenAI,
  and Qwen engines.

**Media:** `[ASSET-voice]`

## 8. Pillar 4 — continuity (kicker: IT FOLLOWS YOU)

**H2:** Close the laptop. Keep the agents.

Your agents live in a background daemon, not the app. Quit the app, lose
Wi-Fi, walk away: they keep working, and the conversation resumes exactly
where it was when you come back. Every past session stays in the history
catalog — reopen one and the agent respawns with its full transcript.

Bullets:
- **The workspace follows you.** A paired iPhone shows the same panes, the
  same states, the same conversations — structure syncs both ways.
- **End-to-end encrypted, no accounts.** Scan-to-pair is the only identity;
  the relay moves ciphertext it cannot read.

**iOS teaser box (inside this section):**
> **📱 iOS is coming.** Scan-to-pair, end-to-end encrypted, no accounts —
> answer your agent from your pocket while your Mac keeps working.
> `[email input] [Join the TestFlight waitlist]`

**Media:** `[ASSET-continuity]`

## 9. Feature grid (6 cards, one line each)

| | |
|---|---|
| **⌘P command palette** — fuzzy-open any file, command, or session from anywhere. | **Click any path** — instant rich preview: highlighting, Markdown, jump-to-line. |
| **Drag panes like VS Code** — split, dock, swap with drop zones; move panes across workspaces. | **Light, dark, follow-system** — one appearance language across Mac and iOS. |
| **Images in, images out** — paste or attach screenshots; click any image in the chat for a full lightbox. | **Connect the AI you already pay for** — first-run installs your agent and walks the login, one click per provider. |

## 10. Under the hood (for the technical reader)

**H2:** Native, not a wrapper

- **Swift end to end.** AppKit/SwiftUI on macOS, UIKit/SwiftUI on iOS — no
  Electron, no webview. The Mac app idles where a Chromium wrapper warms your
  lap.
- **ACP is the source of truth.** Agents connect over the open
  [Agent Client Protocol](https://agentclientprotocol.com) via our own Swift
  `acpkit`; pane state is protocol truth, never a scraped screen.
- **The daemon owns the agents.** Clients attach and detach; a phone and a Mac
  can co-view the same agent. Conversations persist in each agent's own
  storage and resume via `session/load`.
- **The relay stays dumb.** Pairing and an E2E-encrypted pipe — keys live only
  on your devices; intelligence never moves server-side.

Link: `Read the architecture notes →` (docs/architecture.md via GitHub)

## 11. Privacy (short, boxed)

**H2:** Yours, on your machine

No accounts — pairing is the only identity. Telemetry is off by default and
strictly opt-in: a closed set of feature counters, never conversation content.
Voice audio goes to the speech provider through the Bento relay (keys live
server-side), or directly with your own key. Conversations never leave your
machines except through the end-to-end-encrypted relay to your own paired
devices.

## 12. FAQ

- **Which agents does it work with?** Ten presets — Claude Code, Codex,
  Gemini CLI, OpenCode, Cursor Agent, Copilot CLI, Amp, OpenClaw, Hermes,
  Antigravity — plus Kimi, GLM, and DeepSeek via your own API key, plus any
  custom command that speaks ACP.
- **What is ACP?** The [Agent Client Protocol](https://agentclientprotocol.com)
  — an open standard that agents like Claude Code and Gemini CLI speak
  natively. It's why Bento gets real markdown, diffs, and permission prompts
  instead of scraping a terminal.
- **Do I need an API key?** No. Connect the subscription you already pay for —
  first-run installs the agent and walks you through its own login (Claude,
  ChatGPT, Gemini, Copilot). API keys are an option, not a requirement.
- **Do my agents die when I quit the app?** No — they live in a background
  daemon. Quit, reopen, and the conversation resumes where it was.
- **Intel Macs?** Not currently — Apple Silicon, macOS 14+.
- **What does it cost?** The app is free and open source (Apache-2.0). Hosted
  conveniences (like the zero-config voice relay) are free while in beta;
  optional paid services may come later. BYOK always stays free.
- **When is iOS coming?** TestFlight beta is in preparation — join the
  waitlist above.
- **Where do I report bugs?** GitHub issues. The bug tracker is public — you
  can watch fixes land.

## 13. Final CTA

**H2:** Your agents are already working. Stop tab-hunting them.

`[Download for Mac]` — Free & open source · macOS 14+ · Apple Silicon
`brew install NovaShang/bento/bento-terminal` shown small underneath
(labelled: "CLI + daemon for headless hosts").

## 14. Footer

Bento 🍱 · GitHub · Releases · README (中文) · Apache-2.0 · Built by
[@NovaShang](https://github.com/NovaShang)

---

# Asset Production List

| Slot | Type | Spec |
|---|---|---|
| `[ASSET-hero]` | 20–30s autoplay loop (muted, no audio needed) or static PNG fallback | THE money shot: Parallel 2×2, four agent conversations in four states (amber "waiting" title bar is the eye magnet), sidebar visible, dark theme, Retina. If video: amber permission card appears → user holds voice → transcript in glass panel → slide-send → pane turns blue. Real repos, real tasks, no secrets. |
| `[ASSET-states]` | Static PNG (annotated) | Close crop of 4 pane title bars showing the four state glyphs (play / question / check / ring) + the sidebar rows with the same language. Callout labels: working / waiting for you / done / idle. |
| `[ASSET-conversation]` | 10–15s loop | One pane: markdown streaming in, a tool card expanding to a unified diff, a permission card approved with ⌘⏎. This is the "not a scraped screen" proof. |
| `[ASSET-voice]` | 10–15s loop | Right-click-hold on a pane: glass panel appears, user speaks (mixed zh/en line), transcript in the preview bubble, slide-up to send. Big font so the transcript is legible at 720px. |
| `[ASSET-continuity]` | 15s loop or 3-frame sequence | Mac with a working agent → app quits (daemon stays) → reopen → transcript intact and still streaming. If the iOS build is demo-ready: extend with lid-close → same workspace on iPhone → approve a permission from the phone. Stage on real devices only — never fake the handoff. |
| `[ASSET-og]` | 1200×630 PNG | Logo + tagline + the 4-state pane strip. Dark. |

# Implementation notes

- Host: Cloudflare Pages (same account as relay); static, no framework needed.
- Routes the app already links (must exist at launch):
  - `/mac` → 302 to the `releases/latest/download/Bento-macos-arm64.zip`
    permalink (no per-release edits needed). Linked from iOS onboarding.
  - `/ios` → redirect to the waitlist section anchor until TestFlight exists.
    Linked from the Mac first-run QR code.
  - `/install.sh` → serve the headless daemon install script (Linux/WSL
    hosts). Linked from iOS onboarding path B.
- Waitlist: add a `POST /v1/waitlist` route to the existing relay worker (KV
  or D1, email + timestamp, rate-limited like other routes) — no third-party
  form service, consistent with the privacy story.
- Analytics: Cloudflare's built-in only. No third-party trackers — the privacy
  section is a product claim, the site must live by it.
