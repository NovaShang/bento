package acphost

// The tmux WRITE path (docs/tmux-host-design.md §协议扩展 item 4): the
// `structure` op executes one client StructureVerb against the tmux server,
// and the `resize` op sets one pane's geometry. Both follow the same shape —
// translate → run over the control client → Barrier (a fresh re-list whose
// mirror write completes before the barrier returns) → ack the rev that
// therefore already shows the effect. The mirror machinery in tmuxpane.go
// stays the single statekv write path; nothing here touches statekv
// directly.
//
// Verb → tmux command table (v1, one session per target):
//
//	splitPane     split-window -h|-v -t %N [-c cwd] [cmd]
//	newPane       new-window [-c cwd] [cmd]         (one pane, own window)
//	killPane      kill-pane -t %N
//	selectPane    [select-window -t @W] select-pane -t %N
//	renamePane    select-pane -t %N -T title        (pane_title — what the
//	              frozen product's pane title bars and List rows showed)
//	toggleZoom    resize-pane -Z -t %N
//	swapPane      swap-pane -U|-D -t %N
//	swapPanes     swap-pane -s %A -t %B
//	dockPane      move-pane -h|-v [-b] -s %S -t %T
//	resizePane    resize-pane -t %N -L|-R|-U|-D amount
//	reorderPanes  swap-window -d -s @A -t @B chain (requires one pane per
//	              window — the Parallel shape; otherwise structureFailed)
//	applyTiled    join-pane -d -s %i -t %i-1 chain, then
//	              select-layout -t @base tiled
//	renameSession rename-session name               (the managed session)
//
// No faithful v1 translation — these reply structureFailed instead of
// approximating: createSession and movePane(toSession) need a second
// session on the target (multi-session is a later step, tmuxhost.EnsureLocal
// refuses it today), and killSession would tear down the control client
// hosting every pane, which no structure ack could ever report honestly.

import (
	"errors"
	"fmt"
	"strings"
	"time"

	tmuxhost "github.com/novashang/bento/daemon/internal/host/tmux"
	"github.com/novashang/bento/daemon/internal/tmuxcm"
)

// structureBarrierTimeout bounds the post-verb re-list. Generous: a barrier
// may queue behind an in-flight refresh, each of which waits on two listing
// commands.
const structureBarrierTimeout = 15 * time.Second

// StructureVerb is the wire form of the client's StructureAuthority verb
// vocabulary (modules/BentoWorkbench/StructureAuthority.swift), field names
// snake_cased. Kind selects the verb; the other fields carry that verb's
// associated values and are ignored otherwise. Pane numbers are tmux pane
// ids without the % sigil (verb {"kind":"killPane","pane":5} kills %5);
// session names are tmux session names.
type StructureVerb struct {
	Kind string `json:"kind"`

	Name string `json:"name,omitempty"` // createSession/killSession/renameSession
	To   string `json:"to,omitempty"`   // renameSession/renamePane: the new name

	Session string `json:"session,omitempty"` // splitPane/newPane/reorderPanes/applyTiled
	Cwd     string `json:"cwd,omitempty"`     // createSession/splitPane/newPane
	Command string `json:"command,omitempty"` // splitPane/newPane: program to run

	Target     int  `json:"target,omitempty"`     // splitPane: pane to split
	Pane       int  `json:"pane,omitempty"`       // pane-addressed verbs
	Horizontal bool `json:"horizontal,omitempty"` // splitPane/dockPane: split axis
	Up         bool `json:"up,omitempty"`         // swapPane: -U vs -D
	A          int  `json:"a,omitempty"`          // swapPanes
	B          int  `json:"b,omitempty"`          // swapPanes
	Source     int  `json:"source,omitempty"`     // dockPane: pane being moved
	At         int  `json:"at,omitempty"`         // dockPane: pane docked against
	Before     bool `json:"before,omitempty"`     // dockPane: left/top instead of right/bottom

	ToSession string `json:"to_session,omitempty"` // movePane
	Direction string `json:"direction,omitempty"`  // resizePane: L/R/U/D
	Amount    int    `json:"amount,omitempty"`     // resizePane: cells
	Order     []int  `json:"order,omitempty"`      // reorderPanes: pane numbers
}

// tmuxClientFor resolves the live control client for a target — the guard
// every tmux op behind the ensure shares.
func (s *Server) tmuxClientFor(target string) (*tmuxhost.Client, error) {
	s.tmuxMu.Lock()
	host := s.tmuxHost
	s.tmuxMu.Unlock()
	if host == nil {
		return nil, errors.New("tmux session not ensured — spawn with kind=tmux first")
	}
	cli := host.Client(target)
	if cli == nil {
		return nil, fmt.Errorf("tmux target %q not ensured", target)
	}
	return cli, nil
}

// handleStructureOp is the `structure` control op.
func (t *session) handleStructureOp(c Control) {
	target := c.Target
	if target == "" {
		target = tmuxhost.LocalTarget
	}
	fail := func(err error) {
		t.sendControl(Control{Op: "structureFailed", Target: target, Error: err.Error()})
	}
	if c.Verb == nil || c.Verb.Kind == "" {
		fail(errors.New("structure op carries no verb"))
		return
	}
	rev, err := t.server.applyStructureVerb(target, c.Verb)
	if err != nil {
		t.log.Info("structure verb failed", "kind", c.Verb.Kind, "err", err)
		fail(err)
		return
	}
	t.log.Info("structure verb applied", "kind", c.Verb.Kind, "rev", rev)
	t.sendControl(Control{Op: "structureApplied", Target: target, Rev: rev})
}

// handleResizeOp is the `resize` control op: per-pane geometry
// (resize-pane -x -y). Same ack contract as structure — the rev's mirror
// value carries the pane's new size in its window's Details.
func (t *session) handleResizeOp(c Control) {
	fail := func(err error) {
		t.sendControl(Control{Op: "structureFailed", AgentID: c.AgentID, Error: err.Error()})
	}
	target, pane, ok := parseTmuxAgentID(c.AgentID)
	if !ok {
		fail(fmt.Errorf("resize wants a tmux pane agent_id (tmux:<target>:%%N), got %q", c.AgentID))
		return
	}
	if c.Cols <= 0 || c.Rows <= 0 {
		fail(fmt.Errorf("resize wants positive cols and rows, got %dx%d", c.Cols, c.Rows))
		return
	}
	cli, err := t.server.tmuxClientFor(target)
	if err != nil {
		fail(err)
		return
	}
	rev, err := t.server.execAndAckRev(target, cli, []tmuxcm.Command{
		tmuxcm.ResizePane(pane, c.Cols, c.Rows),
	})
	if err != nil {
		fail(err)
		return
	}
	t.log.Info("tmux pane resized", "pane", c.AgentID, "cols", c.Cols, "rows", c.Rows, "rev", rev)
	t.sendControl(Control{Op: "structureApplied", AgentID: c.AgentID, Target: target, Rev: rev})
}

// applyStructureVerb translates and executes one verb, returning the mirror
// rev that includes its effect.
func (s *Server) applyStructureVerb(target string, v *StructureVerb) (uint64, error) {
	cli, err := s.tmuxClientFor(target)
	if err != nil {
		return 0, err
	}
	// renameSession goes through the client's dedicated path: the tracked
	// session name must move WITH the command's reply — the %session-renamed
	// notification can lose the race against the barrier's re-list, which
	// targets the session by name.
	if v.Kind == "renameSession" {
		if v.Name != "" && v.Name != cli.SessionName() {
			return 0, fmt.Errorf("unknown session %q (this target manages %q; multi-session is a later step)",
				v.Name, cli.SessionName())
		}
		if v.To == "" {
			return 0, errors.New("renameSession wants a non-empty new name")
		}
		resp, err := cli.RenameSession(v.To)
		if err != nil {
			return 0, err
		}
		if resp.IsError {
			return 0, fmt.Errorf("tmux refused rename-session: %s", strings.TrimSpace(resp.Output))
		}
		return s.barrierRev(target, cli)
	}
	cmds, err := translateStructureVerb(cli, v)
	if err != nil {
		return 0, err
	}
	return s.execAndAckRev(target, cli, cmds)
}

// execAndAckRev runs the command batch, barriers for the refresh that
// re-lists AFTER the batch (same connection — tmux executes in order), and
// returns the mirror rev current once that refresh has been PUBLISHED
// (Barrier returns only after OnStructure delivery, i.e. after
// mirrorTmuxStructure's setState). A multi-command verb that fails midway
// reports which command tmux refused; earlier commands stand — the mirror
// then honestly shows the partial state, which is why the error names the
// command instead of pretending nothing happened.
func (s *Server) execAndAckRev(target string, cli *tmuxhost.Client, cmds []tmuxcm.Command) (uint64, error) {
	for _, cmd := range cmds {
		resp, err := cli.Exec(cmd)
		if err != nil {
			return 0, err
		}
		if resp.IsError {
			return 0, fmt.Errorf("tmux refused %q: %s", cmd, strings.TrimSpace(resp.Output))
		}
	}
	return s.barrierRev(target, cli)
}

// barrierRev waits out one full post-write refresh pass and returns the
// mirror rev current once it has been published.
func (s *Server) barrierRev(target string, cli *tmuxhost.Client) (uint64, error) {
	if err := cli.Barrier(structureBarrierTimeout); err != nil {
		return 0, err
	}
	s.tmuxMu.Lock()
	rev := s.tmuxRev[target]
	s.tmuxMu.Unlock()
	return rev, nil
}

// translateStructureVerb turns one wire verb into the tmux command batch
// that realizes it (see the table in the file comment).
func translateStructureVerb(cli *tmuxhost.Client, v *StructureVerb) ([]tmuxcm.Command, error) {
	// Verbs that carry a session name must mean the one session this target
	// manages; "" is accepted as "the managed one".
	checkSession := func(name string) error {
		if name == "" || name == cli.SessionName() {
			return nil
		}
		return fmt.Errorf("unknown session %q (this target manages %q; multi-session is a later step)",
			name, cli.SessionName())
	}

	switch v.Kind {
	case "splitPane":
		if err := checkSession(v.Session); err != nil {
			return nil, err
		}
		pane := tmuxcm.PaneID(v.Target)
		return []tmuxcm.Command{
			tmuxcm.SplitWindow(&pane, v.Horizontal, v.Cwd, tmuxcm.ShellSpawn(v.Command)),
		}, nil

	case "newPane":
		if err := checkSession(v.Session); err != nil {
			return nil, err
		}
		// A standalone pane is a new window holding one pane — the
		// cross-window model's "new pane", same as the frozen product. The
		// window is left unnamed so tmux's automatic-rename keeps working.
		return []tmuxcm.Command{
			tmuxcm.NewWindow("", "", v.Cwd, tmuxcm.ShellSpawn(v.Command)),
		}, nil

	case "killPane":
		return []tmuxcm.Command{tmuxcm.KillPane(tmuxcm.PaneID(v.Pane))}, nil

	case "selectPane":
		// Focusing a pane in another window means selecting that window
		// too — the client's "selectPane" is "put my focus here", not
		// tmux's narrower per-window notion.
		pane := tmuxcm.PaneID(v.Pane)
		_, panes, err := cli.ListStructure()
		if err != nil {
			return nil, err
		}
		var cmds []tmuxcm.Command
		found := false
		for _, p := range panes {
			if p.ID != pane {
				continue
			}
			found = true
			if p.HasWindowID && !p.InActiveWindow {
				cmds = append(cmds, tmuxcm.SelectWindow(p.WindowID))
			}
			break
		}
		if !found {
			return nil, fmt.Errorf("no pane %s in session %q", pane, cli.SessionName())
		}
		return append(cmds, tmuxcm.SelectPane(pane)), nil

	case "renamePane":
		// pane_title via select-pane -T: exactly what the frozen product's
		// pane title bars and List rows rendered. Note a foreground TUI can
		// overwrite it via OSC, and tmux emits no notification for it — the
		// verb's own barrier is what lands it in the mirror.
		return []tmuxcm.Command{tmuxcm.SetPaneTitle(tmuxcm.PaneID(v.Pane), v.To)}, nil

	case "toggleZoom":
		return []tmuxcm.Command{tmuxcm.ZoomPane(tmuxcm.PaneID(v.Pane))}, nil

	case "swapPane":
		if v.Up {
			return []tmuxcm.Command{tmuxcm.SwapPaneUp(tmuxcm.PaneID(v.Pane))}, nil
		}
		return []tmuxcm.Command{tmuxcm.SwapPaneDown(tmuxcm.PaneID(v.Pane))}, nil

	case "swapPanes":
		return []tmuxcm.Command{
			tmuxcm.SwapPanes(tmuxcm.PaneID(v.A), tmuxcm.PaneID(v.B)),
		}, nil

	case "dockPane":
		// move-pane, not join-pane: legal within one window too, which is
		// what a drop-zone drag inside a window needs.
		return []tmuxcm.Command{
			tmuxcm.MovePane(tmuxcm.PaneID(v.Source), tmuxcm.PaneID(v.At), v.Horizontal, v.Before),
		}, nil

	case "resizePane":
		dir := strings.ToUpper(v.Direction)
		switch dir {
		case "L", "R", "U", "D":
		default:
			return nil, fmt.Errorf("resizePane direction must be L/R/U/D, got %q", v.Direction)
		}
		if v.Amount <= 0 {
			return nil, fmt.Errorf("resizePane amount must be positive, got %d", v.Amount)
		}
		return []tmuxcm.Command{
			tmuxcm.ResizePaneBy(tmuxcm.PaneID(v.Pane), dir, v.Amount),
		}, nil

	case "reorderPanes":
		if err := checkSession(v.Session); err != nil {
			return nil, err
		}
		return translateReorderPanes(cli, v.Order)

	case "applyTiled":
		if err := checkSession(v.Session); err != nil {
			return nil, err
		}
		return translateApplyTiled(cli)

	// renameSession is handled in applyStructureVerb (the tracked session
	// name must move synchronously with the reply — see there).

	case "createSession":
		return nil, errors.New(
			"createSession has no v1 translation: one tmux session per target until the multi-session step")
	case "killSession":
		return nil, errors.New(
			"killSession is refused in v1: it would tear down the control client hosting every pane " +
				"(one session per target until the multi-session step)")
	case "movePane":
		return nil, errors.New(
			"movePane targets another session; one tmux session per target until the multi-session step")

	default:
		return nil, fmt.Errorf("unknown structure verb %q", v.Kind)
	}
}

// translateReorderPanes sorts the session's windows so the session-wide pane
// order becomes `order`. Only defined when every pane occupies its own
// window (the Parallel shape) — then pane order IS window order and a
// swap-window chain realizes it exactly. Any richer shape has no faithful
// tmux translation of "reorder this flat list", so it refuses.
func translateReorderPanes(cli *tmuxhost.Client, order []int) ([]tmuxcm.Command, error) {
	windows, panes, err := cli.ListStructure()
	if err != nil {
		return nil, err
	}
	if len(order) != len(panes) {
		return nil, fmt.Errorf("reorderPanes order names %d panes, session has %d", len(order), len(panes))
	}
	paneWindow := make(map[tmuxcm.PaneID]tmuxcm.WindowID, len(panes))
	perWindow := make(map[tmuxcm.WindowID]int, len(windows))
	for _, p := range panes {
		if !p.HasWindowID {
			return nil, errors.New("pane listing carried no window ids")
		}
		paneWindow[p.ID] = p.WindowID
		perWindow[p.WindowID]++
	}
	for id, n := range perWindow {
		if n > 1 {
			return nil, fmt.Errorf(
				"reorderPanes is only defined when every pane has its own window; window %s holds %d", id, n)
		}
	}

	// Desired window order ← the window of each pane in requested order.
	desired := make([]tmuxcm.WindowID, 0, len(order))
	seen := make(map[tmuxcm.PaneID]bool, len(order))
	for _, n := range order {
		id := tmuxcm.PaneID(n)
		w, ok := paneWindow[id]
		if !ok {
			return nil, fmt.Errorf("reorderPanes names pane %s, which is not in this session", id)
		}
		if seen[id] {
			return nil, fmt.Errorf("reorderPanes names pane %s twice", id)
		}
		seen[id] = true
		desired = append(desired, w)
	}

	// Selection sort by id: windows[i] is index order (list-windows order),
	// and swap-window -d exchanges two windows' positions.
	current := make([]tmuxcm.WindowID, 0, len(windows))
	for _, w := range windows {
		if perWindow[w.ID] > 0 {
			current = append(current, w.ID)
		}
	}
	var cmds []tmuxcm.Command
	for i := range desired {
		if current[i] == desired[i] {
			continue
		}
		j := -1
		for k := i + 1; k < len(current); k++ {
			if current[k] == desired[i] {
				j = k
				break
			}
		}
		if j < 0 {
			return nil, fmt.Errorf("window %s vanished during reorder", desired[i])
		}
		cmds = append(cmds, tmuxcm.SwapWindows(desired[i], current[i]))
		current[i], current[j] = current[j], current[i]
	}
	return cmds, nil
}

// translateApplyTiled gathers every pane of the session into the first
// pane's window — the join-pane chain, each pane targeting the previous, so
// the session-wide order becomes the window order — and applies the tiled
// layout. Panes already in the base window keep their place in the chain
// but need no join (join-pane refuses same-window moves).
func translateApplyTiled(cli *tmuxhost.Client) ([]tmuxcm.Command, error) {
	_, panes, err := cli.ListStructure()
	if err != nil {
		return nil, err
	}
	if len(panes) == 0 {
		return nil, errors.New("session has no panes")
	}
	if !panes[0].HasWindowID {
		return nil, errors.New("pane listing carried no window ids")
	}
	baseWindow := panes[0].WindowID
	if len(panes) == 1 {
		// One pane fills its window; tiled is a no-op but still legal.
		return []tmuxcm.Command{tmuxcm.SelectLayout(baseWindow, "tiled")}, nil
	}
	cmds := make([]tmuxcm.Command, 0, len(panes))
	prev := panes[0].ID
	for _, p := range panes[1:] {
		if p.WindowID != baseWindow {
			cmds = append(cmds, tmuxcm.JoinPane(p.ID, prev))
		}
		prev = p.ID
	}
	return append(cmds, tmuxcm.SelectLayout(baseWindow, "tiled")), nil
}
