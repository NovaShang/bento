package tmuxcm

// Ported from swift-tmux Tests/SwiftTmuxTests/StructureSnapshotTests.swift
// (every vector).

import (
	"reflect"
	"slices"
	"strings"
	"testing"
)

// mixedSnapshot: 3 windows, the middle one holding two panes — the ordinary
// tmux shape that the old single-layout memory could not describe at all.
func mixedSnapshot() StructureSnapshot {
	return StructureSnapshot{Windows: []SnapshotWindow{
		{Index: 0, Name: "editor", Layout: "b25d,80x24,0,0,1", Panes: []PaneID{1}},
		{Index: 1, Name: "server",
			Layout: "6b1f,120x40,0,0{60x40,0,0,2,59x40,61,0,3}",
			Panes:  []PaneID{2, 3}},
		{Index: 2, Name: "logs", Layout: "a11e,80x24,0,0,4", Panes: []PaneID{4}},
	}}
}

func livePanes(ids ...PaneID) map[PaneID]bool {
	m := make(map[PaneID]bool, len(ids))
	for _, id := range ids {
		m[id] = true
	}
	return m
}

// --- Storage ---

func TestSnapshotRoundTripsThroughStorage(t *testing.T) {
	mixed := mixedSnapshot()
	encoded, err := mixed.Encoded()
	if err != nil {
		t.Fatalf("Encoded: %v", err)
	}
	decoded, ok := DecodeStructureSnapshot(encoded)
	if !ok || !reflect.DeepEqual(decoded, mixed) {
		t.Fatalf("round trip lost data:\n  in:  %+v\n  out: %+v (ok=%v)", mixed, decoded, ok)
	}
}

// The stored form must not contain anything tmux's command lexer treats as
// syntax. A layout string carries braces, and an unquoted brace once made
// the whole set-option fail with a silent syntax error (114ef43).
func TestSnapshotStoredFormIsInertToTmuxLexer(t *testing.T) {
	encoded, err := mixedSnapshot().Encoded()
	if err != nil {
		t.Fatalf("Encoded: %v", err)
	}
	if strings.ContainsAny(encoded, "{};#'\"\\ []") {
		t.Fatalf("stored snapshot must be base64-clean; got: %s", encoded)
	}
}

func TestSnapshotDecodeRejectsGarbageInsteadOfCrashing(t *testing.T) {
	for _, bad := range []string{"", "not base64 at all !!", "aGVsbG8="} {
		if _, ok := DecodeStructureSnapshot(bad); ok {
			t.Errorf("decode accepted garbage %q", bad)
		}
	}
}

func TestSnapshotWindowNameWithLexerHazardsSurvives(t *testing.T) {
	snap := StructureSnapshot{Windows: []SnapshotWindow{
		{Index: 0, Name: `it's #{weird}; "really"`, Panes: []PaneID{1}},
	}}
	encoded, err := snap.Encoded()
	if err != nil {
		t.Fatalf("Encoded: %v", err)
	}
	decoded, ok := DecodeStructureSnapshot(encoded)
	if !ok || !reflect.DeepEqual(decoded, snap) {
		t.Fatalf("hazardous name lost: %+v (ok=%v)", decoded, ok)
	}
}

// --- Restore planning ---

func TestSnapshotPlanRebuildsEveryWindowNotJustOne(t *testing.T) {
	plan := mixedSnapshot().RestorePlan(livePanes(1, 2, 3, 4))
	if len(plan) != 3 {
		t.Fatalf("want 3 steps, got %d", len(plan))
	}
	if plan[0].Base != 1 || plan[1].Base != 2 || plan[2].Base != 4 {
		t.Errorf("bases = %v %v %v", plan[0].Base, plan[1].Base, plan[2].Base)
	}
	if len(plan[0].Join) != 0 || !slices.Equal(plan[1].Join, []PaneID{3}) || len(plan[2].Join) != 0 {
		t.Errorf("joins = %v %v %v", plan[0].Join, plan[1].Join, plan[2].Join)
	}
	if plan[0].Name != "editor" || plan[1].Name != "server" || plan[2].Name != "logs" {
		t.Errorf("names = %v %v %v", plan[0].Name, plan[1].Name, plan[2].Name)
	}
}

// Join order IS the geometry mapping: select-layout fills the saved
// layout's slots by window order and ignores the pane ids inside the
// string, so a reordered join puts every pane in the wrong cell.
func TestSnapshotJoinOrderFollowsCaptureOrder(t *testing.T) {
	snap := StructureSnapshot{Windows: []SnapshotWindow{
		{Index: 0, Name: "w", Layout: "L", Panes: []PaneID{7, 3, 9}},
	}}
	plan := snap.RestorePlan(livePanes(3, 7, 9))
	if len(plan) != 1 || plan[0].Base != 7 || !slices.Equal(plan[0].Join, []PaneID{3, 9}) {
		t.Fatalf("plan = %+v", plan)
	}
}

func TestSnapshotDeadPanesDropOutAndTheirWindowDisappears(t *testing.T) {
	plan := mixedSnapshot().RestorePlan(livePanes(1, 3))
	if len(plan) != 2 {
		t.Fatalf("want 2 steps, got %d: %+v", len(plan), plan)
	}
	// Window "server" lost pane 2, so surviving pane 3 becomes the base.
	if plan[0].Base != 1 || plan[1].Base != 3 {
		t.Errorf("bases = %v %v", plan[0].Base, plan[1].Base)
	}
	// Window "logs" had only pane 4, which is gone — no step at all.
	for _, step := range plan {
		if step.Name == "logs" {
			t.Error("dead window still planned")
		}
	}
}

// A layout string encodes an exact pane count. If a pane died the geometry
// no longer fits, so the plan drops it and the caller falls back to tmux's
// even layout rather than applying something tmux will reject.
func TestSnapshotPartialSurvivalDropsTheSavedLayout(t *testing.T) {
	plan := mixedSnapshot().RestorePlan(livePanes(1, 3, 4))
	for _, step := range plan {
		switch step.Name {
		case "server":
			if step.Layout != "" {
				t.Errorf("dead pane must invalidate the saved layout, got %q", step.Layout)
			}
		case "editor":
			// Untouched windows keep theirs.
			if step.Layout != "b25d,80x24,0,0,1" {
				t.Errorf("untouched layout lost: %q", step.Layout)
			}
		}
	}
}

// Panes created while rearranged are not in the snapshot; they must be left
// where they are, never yanked into an arbitrary window.
func TestSnapshotUnknownPanesAreNotPlanned(t *testing.T) {
	plan := mixedSnapshot().RestorePlan(livePanes(1, 2, 3, 4, 99))
	for _, step := range plan {
		if step.Base == 99 || slices.Contains(step.Join, 99) {
			t.Fatalf("unknown pane planned: %+v", step)
		}
	}
}

func TestSnapshotEmptySurvivalYieldsEmptyPlan(t *testing.T) {
	if plan := mixedSnapshot().RestorePlan(livePanes()); len(plan) != 0 {
		t.Fatalf("got %+v, want empty", plan)
	}
}

func TestSnapshotAllPanesIsWindowThenPaneOrder(t *testing.T) {
	if got := mixedSnapshot().AllPanes(); !slices.Equal(got, []PaneID{1, 2, 3, 4}) {
		t.Fatalf("got %v", got)
	}
}
