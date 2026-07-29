# SwiftTmux

A pure-Swift client for tmux's [control mode (`tmux -CC`)](https://github.com/tmux/tmux/wiki/Control-Mode) protocol, plus parsers for the human-readable `tmux ls` / `list-panes` / `list-windows` formats.

The package is transport-agnostic: feed it bytes from any source (SSH, local pipe, mock), get back parsed notifications and command responses.

## Status

Pre-1.0. API may move around. Used in production by [SpeakTerm](https://github.com/GaoShang/speakterm) (an iOS terminal app).

## Features

- **Control mode protocol** — `%begin`/`%end` response queue (matches replies to awaiting callers by FIFO, since tmux command numbers are global, not per-client).
- **Notifications** — `%output`, `%layout-change`, `%window-add/close/renamed`, `%session-changed/renamed`, `%pane-mode-changed`, `%exit`.
- **Input batching** — 16ms-debounced `send-keys -H <hex>` per pane.
- **UTF-8 safe** — `%output` is unescaped from raw bytes, never via `String`, so box-drawing chars and other multi-byte sequences survive.
- **Type-safe commands** — `TmuxCommand` enum + `commandString` builder covers split/select/zoom/kill/resize/capture/list.
- **Output parsers** — `parsePaneList`, `parseWindowList`, `parseTmuxLs`. The `tmux ls` parser is designed to survive a noisy interactive shell (zsh syntax highlighting, OSC title sequences, CRLF line endings, command echo).
- **ANSI stripping** — `ANSI.strip(_:)` removes CSI / OSC (BEL- or ESC-terminated) / bare-ESC sequences via regex.

## Quick start

```swift
import SwiftTmux

let tmux = TmuxControlMode()
tmux.sendToSSH = { string in /* write to your SSH stdin */ }
tmux.onNotification = { notification in
    switch notification {
    case .output(let pane, let data): /* feed data into a terminal view */
        break
    case .layoutChange(let window, let layout): break
    case .exit(let reason): break
    default: break
    }
}
tmux.logHandler = { print("[tmux] \($0)") }

// Feed bytes you read from SSH:
tmux.feedData(receivedData)

// Send commands:
let panes = await tmux.send(.listPanes())
tmux.sendFireAndForget(.selectPane(id: TmuxPaneID(0)))
```

## Why this exists

Most non-trivial tmux integrations rewrite the same protocol parser. Worse, several edge cases bite people repeatedly:

- Output bytes interleaved with `%output` notifications must be unescaped on **raw bytes**, not strings — otherwise multi-byte UTF-8 corrupts.
- tmux command numbers are globally incremented, not per-client, so matching responses to callers needs a FIFO queue.
- `tmux ls` output read over a PTY is contaminated by shell echo + OSC title escapes + CRLF endings. Naive parsers either lose lines or trip on `\r\n` being a single Swift grapheme cluster.

SwiftTmux ships fixes for these.

## License

MIT (planned). See LICENSE when published.
