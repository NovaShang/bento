package acphost

// The tmux READ-side status ops behind precise pane-state detection — the
// daemon half of the seam TmuxPaneRuntime flags ("no transport op fetches a
// snapshot yet"). The frozen product judged every pane on a 2s tick: fresh
// pane_current_command + pane_title from list-panes picked the agent rule
// set and answered the cheap title pass (braille spinner = working, ✳ =
// idle); when the title couldn't tell, capture-pane's plain screen text fed
// the region rules (blocked forms, working footers). These two ops restore
// exactly those inputs over the control channel:
//
//	tmuxpanes   {op, target}    → tmuxpanesdata{target, panes:[{pane,command,title,path}]}
//	tmuxcapture {op, agent_id}  → tmuxcapturedata{agent_id, data: base64 plain text}
//
// Deliberately NOT the structure mirror: both inputs flap without structural
// meaning (command with every foreground process, title with every spinner
// frame at ~100ms), so publishing them would mint a mirror rev per flap and
// fan out to every client. Polling read ops keep the mirror's rev discipline
// intact — the reader pays for freshness, nobody else.

import (
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	tmuxhost "github.com/novashang/bento/daemon/internal/host/tmux"
	"github.com/novashang/bento/daemon/internal/tmuxcm"
)

// handleTmuxPanesOp is the `tmuxpanes` control op: every pane on the
// target's server (list-panes -a), with command + title + live cwd
// (pane_current_path — the frozen client's per-pane display-message query,
// answered off the same fresh read; the mirror deliberately omits it, so
// the reader asks here at call time).
func (t *session) handleTmuxPanesOp(c Control) {
	target := c.Target
	if target == "" {
		target = tmuxhost.LocalTarget
	}
	fail := func(err error) {
		t.sendControl(Control{Op: "tmuxpanesdata", Target: target, Error: err.Error()})
	}
	cli, err := t.server.tmuxClientFor(target)
	if err != nil {
		fail(err)
		return
	}
	panes, err := cli.ListAllPanes()
	if err != nil {
		fail(err)
		return
	}
	// Best-effort: the op's primary cargo is state detection (command +
	// title); a cwd read failing must not blank the whole reply. A nil map
	// just answers "" for every pane.
	paths, _ := cli.ListAllPanePaths()
	out := make([]TmuxPaneStatus, 0, len(panes))
	for _, p := range panes {
		out = append(out, TmuxPaneStatus{
			Pane: p.ID.String(), Command: p.CurrentCommand, Title: p.Title,
			Path: paths[p.ID],
		})
	}
	t.sendControl(Control{Op: "tmuxpanesdata", Target: target, Panes: out})
}

// handleTmuxCaptureOp is the `tmuxcapture` control op, in two flavors picked
// by the request's `scrollback` flag:
//
//   - absent (the default): one pane's visible screen as PLAIN text
//     (capture-pane -p -J, no -e — the rule engine matches substrings, and
//     SGR escapes woven into the text would break them).
//   - scrollback:true: the pane's whole history AND screen as RENDERABLE
//     bytes (Client.CapturePaneText — `-e -S -`, \r\n line ends). This is
//     what a client feeds a surface it binds fresh, e.g. after a window
//     switch: tmux is the scrollback authority, so a re-bind costs one
//     capture bounded by the user's own `history-limit` instead of a replay
//     of the pane's event log, whose length grows with session lifetime.
//
// Read-only either way — one capture-pane, no state touched.
func (t *session) handleTmuxCaptureOp(c Control) {
	fail := func(err error) {
		t.sendControl(Control{Op: "tmuxcapturedata", AgentID: c.AgentID, Error: err.Error()})
	}
	target, pane, ok := parseTmuxAgentID(c.AgentID)
	if !ok {
		fail(fmt.Errorf("tmuxcapture wants a tmux pane agent_id (tmux:<target>:%%N), got %q", c.AgentID))
		return
	}
	cli, err := t.server.tmuxClientFor(target)
	if err != nil {
		fail(err)
		return
	}
	var out []byte
	if c.Scrollback {
		if out, err = cli.CapturePaneText(pane); err != nil {
			fail(err)
			return
		}
	} else {
		resp, execErr := cli.Exec(tmuxcm.CapturePane(pane, 0, false))
		if execErr != nil {
			fail(execErr)
			return
		}
		if resp.IsError {
			fail(errors.New(strings.TrimSpace(resp.Output)))
			return
		}
		out = []byte(resp.Output)
	}
	// Chunked like filedata, and for the same reason: a deep scrollback
	// base64-encodes past MaxUnit and ONE oversized unit tears the whole
	// control transport (AcpUnitBuffer refuses it, the stream dies, the
	// structure mirror goes with it). The user's history-limit is theirs to
	// set — 50 000 lines is a couple of MB — so the wire, not a line count
	// of ours, is what gets to impose a chunk size. more=true on all but
	// the last; the client concatenates before decoding.
	b64 := base64.StdEncoding.EncodeToString(out)
	for off := 0; off < len(b64) || off == 0; off += fileDataChunk {
		end := min(off+fileDataChunk, len(b64))
		t.sendControl(Control{
			Op:         "tmuxcapturedata",
			AgentID:    c.AgentID,
			Scrollback: c.Scrollback,
			Data:       b64[off:end],
			More:       end < len(b64),
		})
	}
}
