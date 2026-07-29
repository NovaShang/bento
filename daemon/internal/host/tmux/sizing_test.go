package tmuxhost

import "testing"

// ResolveGoverningSize is the whole size-authority arbiter (docs/
// tmux-host-design.md 步骤 5.5); everything else is bookkeeping around it,
// so the semantics table is pinned case by case here: latest wins by
// declaration order, pinned follows its owner and falls back to latest when
// the owner's declaration is gone, smallest is the per-axis minimum, and no
// declarations at all resolve to the 200×50 launch default.
func TestResolveGoverningSize(t *testing.T) {
	mac := SizeDecl{Key: "1", Cols: 220, Rows: 60}
	ipad := SizeDecl{Key: "2", Cols: 120, Rows: 45}
	phone := SizeDecl{Key: "3", Cols: 80, Rows: 50}

	cases := []struct {
		name   string
		policy string
		decls  []SizeDecl
		owner  string
		cols   int
		rows   int
	}{
		// ---- no declarations: every policy answers the launch default ----
		{"latest/none", SizePolicyLatest, nil, "", defaultCols, defaultRows},
		{"smallest/none", SizePolicySmallest, nil, "", defaultCols, defaultRows},
		{"pinned/none", SizePolicyPinned, nil, "2", defaultCols, defaultRows},

		// ---- latest: declaration order decides, most recent last ----
		{"latest/one", SizePolicyLatest, []SizeDecl{mac}, "", 220, 60},
		{"latest/last-wins", SizePolicyLatest, []SizeDecl{mac, ipad}, "", 120, 45},
		{"latest/order-not-size", SizePolicyLatest, []SizeDecl{ipad, mac}, "", 220, 60},
		// A re-declaration is moved to the end by the caller — the resolver
		// sees it as simply the most recent.
		{"latest/redeclare", SizePolicyLatest,
			[]SizeDecl{ipad, {Key: "1", Cols: 200, Rows: 55}}, "", 200, 55},

		// ---- smallest: per-axis minimum, axes independent ----
		{"smallest/one", SizePolicySmallest, []SizeDecl{mac}, "", 220, 60},
		{"smallest/two", SizePolicySmallest, []SizeDecl{mac, ipad}, "", 120, 45},
		// Cross-axis: ipad has the fewest cols (120→80 via phone), phone the
		// fewest… mixing devices per axis is the point.
		{"smallest/cross-axis", SizePolicySmallest, []SizeDecl{ipad, phone}, "", 80, 45},
		{"smallest/three", SizePolicySmallest, []SizeDecl{mac, ipad, phone}, "", 80, 45},
		// Order is irrelevant to smallest.
		{"smallest/order-blind", SizePolicySmallest, []SizeDecl{phone, mac, ipad}, "", 80, 45},

		// ---- pinned: the owner's declaration governs regardless of order ----
		{"pinned/owner-latest", SizePolicyPinned, []SizeDecl{mac, ipad}, "2", 120, 45},
		{"pinned/owner-not-latest", SizePolicyPinned, []SizeDecl{ipad, mac}, "2", 120, 45},
		{"pinned/owner-smallest-loses", SizePolicyPinned, []SizeDecl{mac, phone, ipad}, "1", 220, 60},
		// Owner gone (stream closed → declaration revoked): fall back to the
		// latest rule — the frozen product's release-on-%client-detached.
		{"pinned/owner-gone", SizePolicyPinned, []SizeDecl{ipad, mac}, "9", 220, 60},
		{"pinned/no-owner", SizePolicyPinned, []SizeDecl{ipad, mac}, "", 220, 60},
		{"pinned/owner-gone-empty", SizePolicyPinned, nil, "9", defaultCols, defaultRows},

		// ---- unknown policy: resolves as latest (callers validate) ----
		{"unknown/latest-rule", "frobnicate", []SizeDecl{mac, ipad}, "", 120, 45},
		{"unknown/empty", "", nil, "", defaultCols, defaultRows},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cols, rows := ResolveGoverningSize(tc.policy, tc.decls, tc.owner)
			if cols != tc.cols || rows != tc.rows {
				t.Fatalf("ResolveGoverningSize(%q, %v, %q) = %dx%d, want %dx%d",
					tc.policy, tc.decls, tc.owner, cols, rows, tc.cols, tc.rows)
			}
		})
	}
}

func TestValidSizePolicy(t *testing.T) {
	for _, ok := range []string{SizePolicyLatest, SizePolicyPinned, SizePolicySmallest} {
		if !ValidSizePolicy(ok) {
			t.Fatalf("%q must be a valid policy", ok)
		}
	}
	for _, bad := range []string{"", "manual", "largest", "Latest", "frobnicate"} {
		if ValidSizePolicy(bad) {
			t.Fatalf("%q must not be a valid policy", bad)
		}
	}
}

func TestDefaultSizing(t *testing.T) {
	got := DefaultSizing()
	want := Sizing{Policy: SizePolicyLatest, Cols: defaultCols, Rows: defaultRows}
	if got != want {
		t.Fatalf("DefaultSizing() = %+v, want %+v", got, want)
	}
}
