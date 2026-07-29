package tmuxcm

import (
	"encoding/base64"
	"encoding/json"
)

// StructureSnapshot is a record of a session's window/pane shape, taken
// before Bento rearranges it so the arrangement can be put back (Swift:
// TmuxStructureSnapshot).
//
// It replaced a pair of options that could only describe ONE window (a lone
// layout string plus a flat pane order). Anything else — the mixed
// `N windows × M panes` shape a tmux user actually builds — was not saved at
// all, so "switch to Focus and back" quietly collapsed the whole session
// into a single window. The model was a subset of tmux's; the MEMORY was
// the part that had to grow.
//
// The JSON wire form differs from Swift's only in how pane ids serialize
// (bare ints here vs Swift Codable's {"raw":N} wrappers); nothing reads one
// side's stored snapshots from the other.
type StructureSnapshot struct {
	Windows []SnapshotWindow `json:"windows"`
}

// SnapshotWindow is one window's remembered shape (Swift:
// TmuxStructureSnapshot.Window).
type SnapshotWindow struct {
	// Index is #{window_index} at capture time. Advisory: indices are
	// reassigned as windows come and go, so restore uses it for ordering
	// only.
	Index int    `json:"index"`
	Name  string `json:"name"`
	// Layout is #{window_layout}, braces and all; "" when uncaptured.
	Layout string `json:"layout,omitempty"`
	// Panes is the pane ids in window order. Pane ids (%N) are stable for a
	// pane's lifetime and survive break-pane/join-pane, which is what makes
	// them usable as the anchor for putting panes back where they were.
	Panes []PaneID `json:"panes"`
}

// AllPanes is every pane the snapshot knows about, in window-then-pane
// order.
func (s StructureSnapshot) AllPanes() []PaneID {
	var out []PaneID
	for _, w := range s.Windows {
		out = append(out, w.Panes...)
	}
	return out
}

// Encoded returns base64 of the JSON, for stashing in a tmux session
// option.
//
// Base64 rather than raw JSON on purpose: a tmux option value is parsed by
// tmux's own command lexer, where `{`, `}`, `;` and `#` are syntax. A layout
// string already carries braces, and that exact hazard silently broke the
// Parallel⇄Focus round-trip once (114ef43 in the Swift lineage — the whole
// set-option failed with a syntax error nobody saw). escapeArg quotes those
// today, but an alphabet of [A-Za-z0-9+/=] cannot be mis-lexed by any future
// change to either side.
func (s StructureSnapshot) Encoded() (string, error) {
	raw, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(raw), nil
}

// DecodeStructureSnapshot reverses Encoded. The bool is false for anything
// that is not a stored snapshot — empty, invalid base64, or a non-snapshot
// payload — mirroring the Swift optional.
func DecodeStructureSnapshot(stored string) (StructureSnapshot, bool) {
	if stored == "" {
		return StructureSnapshot{}, false
	}
	raw, err := base64.StdEncoding.DecodeString(stored)
	if err != nil {
		return StructureSnapshot{}, false
	}
	var snap StructureSnapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		return StructureSnapshot{}, false
	}
	return snap, true
}

// DebugJSON is the JSON for logs — the stored form is unreadable by design,
// so diagnostics print this instead.
func (s StructureSnapshot) DebugJSON() string {
	raw, err := json.Marshal(s)
	if err != nil {
		return "<unencodable>"
	}
	return string(raw)
}

// RestoreStep is what to do to one window when putting the shape back.
type RestoreStep struct {
	// Base is the pane that stays put; every other pane joins into its
	// window.
	Base PaneID
	// Join is the panes to join, in the order they must land for
	// select-layout to map them onto the saved geometry.
	Join []PaneID
	// Layout is the saved layout to apply, "" when it no longer fits.
	Layout string
	Name   string
}

// RestorePlan reconciles the snapshot against the panes that are actually
// still alive and produces one step per window worth rebuilding.
//
// Panes closed while the session was rearranged simply drop out; panes
// created in the meantime are unknown to the snapshot and are left alone in
// their own windows rather than being forced somewhere arbitrary. A window
// whose panes are all gone produces no step. A window reduced to a single
// surviving pane still produces a step (with no joins) so its name can be
// restored.
//
// select-layout assigns panes to geometry slots by their order in the window
// and ignores the pane ids embedded in the layout string, so the join order
// here IS the geometry mapping — get it wrong and every pane lands in the
// wrong cell.
func (s StructureSnapshot) RestorePlan(livePanes map[PaneID]bool) []RestoreStep {
	var steps []RestoreStep
	for _, window := range s.Windows {
		var survivors []PaneID
		for _, p := range window.Panes {
			if livePanes[p] {
				survivors = append(survivors, p)
			}
		}
		if len(survivors) == 0 {
			continue
		}
		// A layout string describes the pane count at capture time; if any
		// pane is gone it no longer fits and tmux would reject or misapply
		// it. Dropping it lets the caller fall back to an even layout.
		layout := ""
		if len(survivors) == len(window.Panes) {
			layout = window.Layout
		}
		steps = append(steps, RestoreStep{
			Base:   survivors[0],
			Join:   survivors[1:],
			Layout: layout,
			Name:   window.Name,
		})
	}
	return steps
}
