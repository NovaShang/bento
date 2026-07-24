# Debug forensics scripts

## lldb-transcript-capture.lldb

Attach-and-dump forensics for the transcript white-pane bug family
(see `~/.claude` memory `project_transcript_whitescreen_on_send` for the full
history). Captures, WITHOUT stopping the app for more than ~2s:

- `/tmp/bento-viewtree.txt` — full `_subtreeDescription` of the main window
- `/tmp/bento-layers.txt` — per-transcript CALayer trees with geometry and a
  `C=1/C=0` contents marker per layer (the white-pane judgment: zero
  contents-bearing layers intersecting the viewport band)

Usage:

```sh
lldb -p $(pgrep -f "Bento ACP.app/Contents/MacOS/Bento ACP" | head -1) \
     -s scripts/debug/lldb-transcript-capture.lldb
```

Ground rules learned the hard way:
- The app must have `get-task-allow` (dev builds do).
- NEVER `po` megabyte strings through lldb — it wedges lldb AND the stopped
  app for minutes, and killing lldb then kills the app. All output is written
  to files from INSIDE the process (`writeToFile:`), which is why this script
  is fast.
- lldb ObjC++ expression quirks encoded here: no variadic calls
  (`appendFormat:` unusable), CGRect type ambiguity (layer geometry read via
  CALayer KVC `position.y` / `bounds.size.height`), don't name a variable `d`.

The runtime scroll diagnostics tracer is separate and opt-in:
`defaults write com.bento.menubar.acp AcpScrollDiag -bool YES` + GUI relaunch →
`/tmp/bento-acp-scroll-diag.log` (anchor ticks, snaps, blank-heal verdicts).
