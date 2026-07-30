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
//	tmuxpanes   {op, target}    → tmuxpanesdata{target, panes:[{pane,command,title}]}
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
// target's server (list-panes -a), with command + title.
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
	out := make([]TmuxPaneStatus, 0, len(panes))
	for _, p := range panes {
		out = append(out, TmuxPaneStatus{
			Pane: p.ID.String(), Command: p.CurrentCommand, Title: p.Title,
		})
	}
	t.sendControl(Control{Op: "tmuxpanesdata", Target: target, Panes: out})
}

// handleTmuxCaptureOp is the `tmuxcapture` control op: one pane's visible
// screen as PLAIN text (capture-pane -p -J, no -e — the rule engine matches
// substrings, and SGR escapes woven into the text would break them).
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
	resp, err := cli.Exec(tmuxcm.CapturePane(pane, 0, false))
	if err != nil {
		fail(err)
		return
	}
	if resp.IsError {
		fail(errors.New(strings.TrimSpace(resp.Output)))
		return
	}
	t.sendControl(Control{
		Op:      "tmuxcapturedata",
		AgentID: c.AgentID,
		Data:    base64.StdEncoding.EncodeToString([]byte(resp.Output)),
	})
}
