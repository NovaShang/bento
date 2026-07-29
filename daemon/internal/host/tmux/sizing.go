package tmuxhost

// Session-size authority (docs/tmux-host-design.md 步骤 5.5): the frozen
// product's three window-size policies (跟随最新 / 以此设备为准 / 最小者)
// arbitrated in the DAEMON. Devices are no longer tmux clients — they are
// acphost streams — so the tmux side stays `window-size latest` with the
// daemon's control client as the only real client, and the daemon resolves
// the governing size from per-stream viewport declarations, then declares it
// via `refresh-client -C` (Client.SetSizing).
//
// Ownership identity for "pinned": the frozen product recorded the owning
// tmux CLIENT name (its tty) in `@bento_size_owner`, precisely because the
// connection was the honest identity — `list-clients` answered "is the owner
// still here?" and `%client-detached` released it with no heartbeat. The
// stream is that connection's successor, so the owner IS the declaring
// stream; the stream closing releases the pin the way %client-detached used
// to. Streams are daemon-internal, so the mirror carries only the display
// label (OwnerDevice) other devices need for "set by Shang iPad Air" UI.
// This file keeps only the PURE half — the resolver and the wire block —
// so it unit-tests exhaustively; the stream bookkeeping lives in acphost.

// The three policies, as they appear on the wire (setSizePolicy verb) and in
// the mirror's sizing block. They map 1:1 onto the frozen product's
// window-size values (latest / manual+owner / smallest); "pinned" rather
// than "manual" because in this architecture nothing is manual about it —
// the owner stream's declaration keeps driving the size.
const (
	SizePolicyLatest   = "latest"
	SizePolicyPinned   = "pinned"
	SizePolicySmallest = "smallest"
)

// ValidSizePolicy reports whether p is one of the three policies. Callers
// validate before storing; the resolver itself treats anything unknown as
// latest rather than guessing a size.
func ValidSizePolicy(p string) bool {
	switch p {
	case SizePolicyLatest, SizePolicyPinned, SizePolicySmallest:
		return true
	}
	return false
}

// Sizing is the resolved size-authority block the structure mirror publishes
// (statekv `tmux/<target>/structure`, field `sizing`): the policy, the
// display label of the pinning device (pinned only), and the governing size
// the daemon's control client currently declares.
type Sizing struct {
	Policy      string `json:"policy"`
	OwnerDevice string `json:"owner_device,omitempty"`
	Cols        int    `json:"cols"`
	Rows        int    `json:"rows"`
}

// DefaultSizing is the block before anyone declares anything: policy latest,
// size the control client's launch default (the pre-5.5 fixed declaration).
func DefaultSizing() Sizing {
	return Sizing{Policy: SizePolicyLatest, Cols: defaultCols, Rows: defaultRows}
}

// SizeDecl is one stream's declared viewport, as the resolver consumes it.
// Key is an opaque stream identity (acphost uses the stream id); the SLICE
// ORDER is declaration order, most recent last — the resolver never sorts.
type SizeDecl struct {
	Key  string
	Cols int
	Rows int
}

// ResolveGoverningSize is the pure arbiter: given the policy, the live
// declarations in declaration order (most recent LAST; a re-declaration must
// have been moved to the end by the caller), and the owner's key (pinned
// only, "" = no owner), it returns the size the control client should
// declare to tmux.
//
//   - latest:   the most recent declaration wins; none → the 200×50 default.
//   - smallest: minimum cols and minimum rows over all declarations,
//     INDEPENDENTLY — tmux's own window-size smallest clamps each axis to
//     the tightest client, and mixing axes from different devices is exactly
//     what "nothing is clipped anywhere" means. None → the default.
//   - pinned:   the owner's declaration. An owner without a declaration
//     (its stream closed, so the declaration was revoked — acphost also
//     reverts the policy, this is the resolver's own belt) falls back to
//     the latest rule, the frozen product's release-on-detach semantics.
//
// Unknown policies resolve as latest: callers validate on the way in, and a
// resolver that returned 0×0 for a typo would clamp every window to nothing.
func ResolveGoverningSize(policy string, decls []SizeDecl, ownerKey string) (cols, rows int) {
	latest := func() (int, int) {
		if len(decls) == 0 {
			return defaultCols, defaultRows
		}
		d := decls[len(decls)-1]
		return d.Cols, d.Rows
	}
	switch policy {
	case SizePolicySmallest:
		if len(decls) == 0 {
			return defaultCols, defaultRows
		}
		cols, rows = decls[0].Cols, decls[0].Rows
		for _, d := range decls[1:] {
			cols = min(cols, d.Cols)
			rows = min(rows, d.Rows)
		}
		return cols, rows
	case SizePolicyPinned:
		if ownerKey != "" {
			for _, d := range decls {
				if d.Key == ownerKey {
					return d.Cols, d.Rows
				}
			}
		}
		return latest()
	default: // SizePolicyLatest and anything unvalidated
		return latest()
	}
}
