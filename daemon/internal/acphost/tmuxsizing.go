package acphost

// Session-size authority, daemon side (docs/tmux-host-design.md 步骤 5.5):
// the stream bookkeeping around tmuxhost.ResolveGoverningSize. Devices are
// acphost STREAMS now, not tmux clients, so the frozen product's three
// window-size policies moved up here whole:
//
//   - `{"op":"viewport","target":…,"cols":C,"rows":R}` is one stream's
//     standing declaration of its grid — the input `window-size` used to
//     read off attached clients. Re-declaring replaces it (and makes this
//     stream the most recent, which is what "latest" arbitrates on); the
//     stream closing revokes it, the role %client-detached played.
//   - the `setSizePolicy` structure verb picks the policy. For "pinned" the
//     OWNER IS THE ISSUING STREAM — the honest successor of the frozen
//     product's `@bento_size_owner = <tmux client name>|<label>`, where the
//     connection was the identity precisely so a vanished device could
//     never hold a session hostage. The verb's owner_device is only the
//     display label other devices show ("set by Shang iPad Air").
//   - the resolved block {policy, owner_device, cols, rows} rides the
//     structure mirror (tmuxStructureState.Sizing) — Client.SetSizing puts
//     it into change detection and declares the size to tmux
//     (refresh-client -C), tmux reflows, %layout-change re-lists, and the
//     ONE mirror write path (mirrorTmuxStructure) publishes. Nothing here
//     touches statekv directly.
//
// Policy and declarations are daemon-memory only, deliberately: every
// declaration and every owner is a stream, streams die with the daemon, and
// the frozen product's release semantics say a world with no declarers IS
// "latest at the default size" — which is exactly what a restart resolves to.

import (
	"errors"
	"fmt"
	"strconv"

	tmuxhost "github.com/novashang/bento/daemon/internal/host/tmux"
)

// targetSizing is one tmux target's authority state, under Server.sizingMu.
type targetSizing struct {
	policy      string // tmuxhost.SizePolicy*; latest until a verb says else
	owner       *session
	ownerDevice string // display label from the pinning verb
	// decls in declaration order, most recent LAST (re-declaring moves a
	// stream to the end) — the order ResolveGoverningSize's "latest" reads.
	decls []viewportDecl
	// resolved is the block the mirror publishes (currentTmuxSizing).
	resolved tmuxhost.Sizing
}

type viewportDecl struct {
	sess *session
	cols int
	rows int
}

func (st *targetSizing) declIndex(t *session) int {
	for i, d := range st.decls {
		if d.sess == t {
			return i
		}
	}
	return -1
}

// sizingStateLocked returns (creating if needed) a target's state. Caller
// holds sizingMu.
func (s *Server) sizingStateLocked(target string) *targetSizing {
	st := s.tmuxSizing[target]
	if st == nil {
		st = &targetSizing{
			policy:   tmuxhost.SizePolicyLatest,
			resolved: tmuxhost.DefaultSizing(),
		}
		s.tmuxSizing[target] = st
	}
	return st
}

// streamKey is the resolver's opaque identity for a stream. Stream ids are
// unique for a daemon's lifetime (relay ids and the local counter never
// collide), which is all the resolver compares.
func streamKey(t *session) string { return strconv.FormatUint(uint64(t.streamID), 10) }

// resolveAndPushLocked re-resolves a target's governing size, stores the
// block for the mirror, and — when the target has a live control client —
// hands it to Client.SetSizing (refresh-client -C + change-detected
// republish). Caller holds sizingMu; no client = ensure hasn't happened yet,
// and recomputeTmuxSizing's call from spawnTmux re-pushes after it has.
func (s *Server) resolveAndPushLocked(target string, st *targetSizing) {
	decls := make([]tmuxhost.SizeDecl, 0, len(st.decls))
	for _, d := range st.decls {
		decls = append(decls, tmuxhost.SizeDecl{Key: streamKey(d.sess), Cols: d.cols, Rows: d.rows})
	}
	ownerKey := ""
	if st.owner != nil {
		ownerKey = streamKey(st.owner)
	}
	cols, rows := tmuxhost.ResolveGoverningSize(st.policy, decls, ownerKey)
	st.resolved = tmuxhost.Sizing{
		Policy: st.policy, OwnerDevice: st.ownerDevice, Cols: cols, Rows: rows,
	}
	if cli, err := s.tmuxClientFor(target); err == nil {
		cli.SetSizing(st.resolved)
	}
}

// recomputeTmuxSizing re-resolves and pushes a target's sizing from outside
// the lock — the ensure path calls it so a viewport declared BEFORE the
// ensure still reaches the fresh control client.
func (s *Server) recomputeTmuxSizing(target string) {
	s.sizingMu.Lock()
	defer s.sizingMu.Unlock()
	s.resolveAndPushLocked(target, s.sizingStateLocked(target))
}

// currentTmuxSizing is the mirror's read: the block the last resolution
// produced, or the default for a target nothing was ever declared on. Never
// called with tmuxMu held (mirrorTmuxStructure reads it after releasing the
// rev section).
func (s *Server) currentTmuxSizing(target string) tmuxhost.Sizing {
	s.sizingMu.Lock()
	defer s.sizingMu.Unlock()
	if st := s.tmuxSizing[target]; st != nil {
		return st.resolved
	}
	return tmuxhost.DefaultSizing()
}

// handleViewportOp is the `viewport` control op: this stream's standing
// grid declaration. A declaration, not a command — there is no ack; the
// mirror's sizing block (republished whenever the resolution changes) is
// the read path, exactly like every other structure fact.
func (t *session) handleViewportOp(c Control) {
	target := c.Target
	if target == "" {
		target = tmuxhost.LocalTarget
	}
	if c.Cols <= 0 || c.Rows <= 0 {
		t.log.Info("viewport ignored: wants positive cols and rows",
			"cols", c.Cols, "rows", c.Rows)
		return
	}
	s := t.server
	s.sizingMu.Lock()
	st := s.sizingStateLocked(target)
	if i := st.declIndex(t); i >= 0 {
		// Re-declaration: replace AND move to most-recent — under "latest"
		// a device that just declared is the active device.
		st.decls = append(st.decls[:i], st.decls[i+1:]...)
	}
	st.decls = append(st.decls, viewportDecl{sess: t, cols: c.Cols, rows: c.Rows})
	s.resolveAndPushLocked(target, st)
	resolved := st.resolved
	s.sizingMu.Unlock()
	t.log.Info("viewport declared", "target", target, "cols", c.Cols, "rows", c.Rows,
		"policy", resolved.Policy, "governing", fmt.Sprintf("%dx%d", resolved.Cols, resolved.Rows))
}

// revokeTmuxViewports drops every declaration a closing stream made and
// releases any pin it owned — policy back to latest, the frozen product's
// %client-detached release. Called from session.Close.
func (s *Server) revokeTmuxViewports(t *session) {
	s.sizingMu.Lock()
	defer s.sizingMu.Unlock()
	for target, st := range s.tmuxSizing {
		changed := false
		if i := st.declIndex(t); i >= 0 {
			st.decls = append(st.decls[:i], st.decls[i+1:]...)
			changed = true
		}
		if st.owner == t {
			st.owner = nil
			st.ownerDevice = ""
			st.policy = tmuxhost.SizePolicyLatest
			changed = true
		}
		if changed {
			s.resolveAndPushLocked(target, st)
		}
	}
}

// applySizePolicyVerb is the `setSizePolicy` structure verb (routed from
// handleStructureOp, which carries the issuing stream — the pinned owner).
// Same ack contract as every verb: the returned rev's mirror value already
// shows the new sizing block, via the same barrier the tmux-command verbs
// use — SetSizing queued the refresh-client on the control connection, so
// the barrier's re-list runs in a world where tmux has processed it.
func (s *Server) applySizePolicyVerb(target string, t *session, v *StructureVerb) (uint64, error) {
	if !tmuxhost.ValidSizePolicy(v.Policy) {
		return 0, fmt.Errorf("setSizePolicy wants policy latest|pinned|smallest, got %q", v.Policy)
	}
	cli, err := s.tmuxClientFor(target)
	if err != nil {
		return 0, err
	}
	s.sizingMu.Lock()
	st := s.sizingStateLocked(target)
	if v.Policy == tmuxhost.SizePolicyPinned {
		// Pinning means "MY grid governs" — meaningless from a stream that
		// never declared one, so refuse rather than pin the default.
		if st.declIndex(t) < 0 {
			s.sizingMu.Unlock()
			return 0, errors.New(
				"setSizePolicy pinned wants a viewport declaration from this stream first (send the viewport op)")
		}
		st.owner = t
		st.ownerDevice = v.OwnerDevice
	} else {
		st.owner = nil
		st.ownerDevice = ""
	}
	st.policy = v.Policy
	s.resolveAndPushLocked(target, st)
	s.sizingMu.Unlock()
	return s.barrierRev(target, cli)
}
