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
// Verb → tmux command table (multi-session: one control client per target,
// every session on the server addressable; verbs that carry a session name
// default "" to the control client's current session):
//
//	splitPane     split-window -h|-v -t %N [-c cwd] [cmd]   (pane ids are
//	              server-global — the session field is not needed to route)
//	newPane       new-window -t <session>: [-c cwd] [cmd]  (one pane, own
//	              window, in the named session)
//	killPane      kill-pane -t %N
//	selectPane    [select-window -t @W] select-pane -t %N  (looked up
//	              server-wide — the pane may live in any session)
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
//	renameSession rename-session -t <name> <to>     (any session; name ""
//	              = the current one)
//	createSession new-session -d -s <name> [-c cwd] (does NOT switch the
//	              control client — ensure is the verb that attaches)
//	killSession   kill-session -t <name>. When the named session is the
//	              control client's current one and others exist, the daemon
//	              switch-clients away first so the client survives; killing
//	              the LAST session takes the whole server (and the control
//	              client) down — allowed, tmux allows it — and the ack rev's
//	              mirror then honestly shows an empty server (session "",
//	              no sessions). The next ensure relaunches from scratch.
//	movePane      break-pane -d -s %N -t <session>: (the pane moves into its
//	              own window in the target session; a pane already alone in
//	              its window moves AS its window — tmux 3.7 allows it, and a
//	              source session emptied by the move is destroyed, exactly
//	              as if the user ran break-pane themselves)
//	setSizePolicy no tmux command of its own — daemon-side size authority
//	              (tmuxsizing.go); the resolved size reaches tmux as
//	              refresh-client -C via Client.SetSizing. Routed from
//	              handleStructureOp directly because the ISSUING STREAM is
//	              the pinned owner, and only the session knows itself.
//
// Refusals are tmux's own (unknown pane/session, break-pane on a solo pane,
// …) plus malformed verbs; there is no "one session per target" boundary
// anymore.

import (
	"errors"
	"fmt"
	"strings"
	"time"

	tmuxhost "github.com/novashang/bento/daemon/internal/host/tmux"
	"github.com/novashang/bento/daemon/internal/tmuxcm"
)

// structureBarrierTimeout bounds the post-verb re-list. Generous: a barrier
// may queue behind an in-flight refresh, each of which waits on a session
// list plus two listing commands per session.
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

	Session string `json:"session,omitempty"` // newPane/reorderPanes/applyTiled ("" = current)
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

	// setSizePolicy: the session-size policy (latest|pinned|smallest) and,
	// for pinned, the display label of the pinning device. The pinned OWNER
	// is not on the wire by design: it is the stream issuing the verb — a
	// device can honestly pin only itself (tmuxsizing.go).
	Policy      string `json:"policy,omitempty"`
	OwnerDevice string `json:"owner_device,omitempty"`
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
	// setSizePolicy is the one verb that needs the ISSUING STREAM (the
	// pinned owner is the declarer, never a name on the wire), so it routes
	// here instead of through applyStructureVerb's session-free path.
	var rev uint64
	var err error
	if c.Verb.Kind == "setSizePolicy" {
		rev, err = t.server.applySizePolicyVerb(target, t, c.Verb)
	} else {
		rev, err = t.server.applyStructureVerb(target, c.Verb)
	}
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
	// killSession routes through its own path: it may need a client switch
	// first, and killing the last session ends the control client itself —
	// flow no command batch can express.
	if v.Kind == "killSession" {
		return s.applyKillSession(target, cli, v)
	}
	cmds, err := translateStructureVerb(cli, v)
	if err != nil {
		return 0, err
	}
	return s.execAndAckRev(target, cli, cmds)
}

// applyKillSession is the killSession verb (see the table in the file
// comment for the three shapes). The decisions run on a FRESH session
// listing, so a kill issued right after a create sees that create's world.
func (s *Server) applyKillSession(target string, cli *tmuxhost.Client, v *StructureVerb) (uint64, error) {
	name := v.Name
	if name == "" {
		name = cli.SessionName()
	}
	rows, err := cli.ListSessions()
	if err != nil {
		return 0, err
	}
	exists := false
	other := "" // any survivor to switch to, by rename-stable id
	for _, row := range rows {
		if row.Name == name {
			exists = true
		} else if other == "" {
			other = row.ID.String()
		}
	}
	current := cli.SessionName()

	// Killing the CURRENT session with survivors: switch away first so the
	// control client outlives the kill (tmux's default detach-on-destroy
	// would otherwise take it down, and with it every pane subscription on
	// the server).
	if exists && name == current && other != "" {
		resp, err := cli.Exec(tmuxcm.SwitchClient(other))
		if err != nil {
			return 0, err
		}
		if resp.IsError {
			return 0, fmt.Errorf("tmux refused switch-client: %s", strings.TrimSpace(resp.Output))
		}
	}

	lastSession := exists && other == ""
	resp, err := cli.Exec(tmuxcm.KillSession(name))
	if !lastSession {
		if err != nil {
			return 0, err
		}
		if resp.IsError {
			return 0, fmt.Errorf("tmux refused kill-session: %s", strings.TrimSpace(resp.Output))
		}
		return s.barrierRev(target, cli)
	}

	// The last session: the kill takes the whole server — and this control
	// client — down (tmux allows it, so we do). The reply usually lands
	// before the %exit (verified live), but a torn transport here IS the
	// success signal, so only a tmux-level refusal fails the verb.
	if err == nil && resp.IsError {
		return 0, fmt.Errorf("tmux refused kill-session: %s", strings.TrimSpace(resp.Output))
	}
	if !cli.WaitClosed(10 * time.Second) {
		return 0, errors.New("kill-session of the last session did not end the control client")
	}
	// No Barrier possible on a dead client; publish the honest empty-server
	// mirror directly. Safe to call from here exactly because WaitClosed
	// proved the client's refresher is gone — this is the only writer left
	// for the target, so the single-write-path discipline holds.
	s.mirrorTmuxStructure(target, "", nil)
	s.tmuxMu.Lock()
	rev := s.tmuxRev[target]
	s.tmuxMu.Unlock()
	return rev, nil
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
	switch v.Kind {
	case "splitPane":
		// Pane ids are server-global; the session field routes nothing here.
		pane := tmuxcm.PaneID(v.Target)
		return []tmuxcm.Command{
			tmuxcm.SplitWindow(&pane, v.Horizontal, v.Cwd, tmuxcm.ShellSpawn(v.Command)),
		}, nil

	case "newPane":
		// A standalone pane is a new window holding one pane — the
		// cross-window model's "new pane", same as the frozen product. The
		// window is left unnamed so tmux's automatic-rename keeps working.
		// The session ("" = the client's current one) picks WHOSE window
		// list it joins; the trailing ':' is tmux target syntax for "next
		// free index in this session".
		sessionTarget := ""
		if v.Session != "" {
			sessionTarget = v.Session + ":"
		}
		return []tmuxcm.Command{
			tmuxcm.NewWindow(sessionTarget, "", v.Cwd, tmuxcm.ShellSpawn(v.Command)),
		}, nil

	case "killPane":
		return []tmuxcm.Command{tmuxcm.KillPane(tmuxcm.PaneID(v.Pane))}, nil

	case "selectPane":
		// Focusing a pane in another window means selecting that window
		// too — the client's "selectPane" is "put my focus here", not
		// tmux's narrower per-window notion. Looked up server-wide: the
		// pane may live in any session.
		pane := tmuxcm.PaneID(v.Pane)
		panes, err := cli.ListAllPanes()
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
			return nil, fmt.Errorf("no pane %s on this tmux server", pane)
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
		return translateReorderPanes(cli, v.Session, v.Order)

	case "applyTiled":
		return translateApplyTiled(cli, v.Session)

	case "renameSession":
		if v.To == "" {
			return nil, errors.New("renameSession wants a non-empty new name")
		}
		from := v.Name
		if from == "" {
			from = cli.SessionName()
		}
		// Addressed by name (`-t`), so any session renames without a client
		// switch. The tracked current-session name follows via
		// %session-renamed (reconciled by rename-stable id on the barrier's
		// own refresh), so the ack rev's mirror already shows the new name.
		return []tmuxcm.Command{tmuxcm.RenameSessionOf(from, v.To)}, nil

	case "createSession":
		if v.Name == "" {
			return nil, errors.New("createSession wants a non-empty name")
		}
		// -d: create WITHOUT switching the control client — ensure (spawn
		// kind=tmux) is the verb that attaches, and %output keeps streaming
		// from the session the user is actually looking at.
		return []tmuxcm.Command{tmuxcm.NewSessionAt(v.Name, v.Cwd)}, nil

	// killSession is handled in applyStructureVerb (it may need a client
	// switch first, and the last-session case outlives no barrier — see
	// applyKillSession).

	case "movePane":
		if v.ToSession == "" {
			return nil, errors.New("movePane wants a non-empty to_session")
		}
		// break-pane -d -s %N -t 'session:': the pane moves into its own
		// window in the target session, keeping its server-global id. A
		// pane already alone in its window moves as that window (verified
		// on tmux 3.7b), and a source session emptied by the move dies —
		// tmux's own semantics, relayed rather than second-guessed.
		return []tmuxcm.Command{
			tmuxcm.BreakPane(tmuxcm.PaneID(v.Pane), "", v.ToSession),
		}, nil

	default:
		return nil, fmt.Errorf("unknown structure verb %q", v.Kind)
	}
}

// translateReorderPanes sorts the session's windows so the session-wide pane
// order becomes `order`. Only defined when every pane occupies its own
// window (the Parallel shape) — then pane order IS window order and a
// swap-window chain realizes it exactly. Any richer shape has no faithful
// tmux translation of "reorder this flat list", so it refuses.
func translateReorderPanes(cli *tmuxhost.Client, session string, order []int) ([]tmuxcm.Command, error) {
	windows, panes, err := cli.ListStructure(session)
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
func translateApplyTiled(cli *tmuxhost.Client, session string) ([]tmuxcm.Command, error) {
	_, panes, err := cli.ListStructure(session)
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
