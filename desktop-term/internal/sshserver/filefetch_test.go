package sshserver

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func mkTree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, d := range []string{
		"a/b", "node_modules/x", "d1/d2/d3/d4/d5",
	} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{
		"top.md", "a/b/deep.txt", "node_modules/x/skip.js", "d1/d2/d3/d4/d5/deep.txt",
	} {
		if err := os.WriteFile(filepath.Join(root, f), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func relPaths(entries []treeEntry) map[string]bool {
	m := make(map[string]bool, len(entries))
	for _, e := range entries {
		m[e.P] = e.D
	}
	return m
}

func TestBuildTreeListBasics(t *testing.T) {
	root := mkTree(t)
	entries, truncated := buildTreeList(root, fileFetchRequest{
		Depth: 4, MaxEntries: 100, Skip: []string{"node_modules"},
	})
	if truncated {
		t.Fatal("unexpected truncation")
	}
	m := relPaths(entries)
	if !m["a"] || m["top.md"] {
		t.Fatalf("dir flags wrong: %v", m)
	}
	if _, ok := m["a/b/deep.txt"]; !ok {
		t.Fatalf("missing nested file: %v", m)
	}
	// Skip-named dir is listed but pruned.
	if _, ok := m["node_modules"]; !ok {
		t.Fatalf("skip dir should still be listed: %v", m)
	}
	if _, ok := m["node_modules/x"]; ok {
		t.Fatalf("skip dir was descended into: %v", m)
	}
}

func TestBuildTreeListDepthBound(t *testing.T) {
	root := mkTree(t)
	entries, _ := buildTreeList(root, fileFetchRequest{Depth: 3, MaxEntries: 100})
	m := relPaths(entries)
	if _, ok := m["d1/d2/d3"]; !ok {
		t.Fatalf("depth-3 entry missing: %v", m)
	}
	if _, ok := m["d1/d2/d3/d4"]; ok {
		t.Fatalf("depth bound not enforced: %v", m)
	}
}

func TestBuildTreeListEntryCapTruncates(t *testing.T) {
	root := mkTree(t)
	entries, truncated := buildTreeList(root, fileFetchRequest{Depth: 8, MaxEntries: 3})
	if len(entries) != 3 || !truncated {
		t.Fatalf("want 3 entries + truncated, got %d %v", len(entries), truncated)
	}
}

func TestBuildTreeListClampsSillyBounds(t *testing.T) {
	root := mkTree(t)
	// Depth 0 / negative entries fall back to defaults instead of listing
	// nothing or everything.
	entries, _ := buildTreeList(root, fileFetchRequest{Depth: 0, MaxEntries: -1})
	if len(entries) == 0 {
		t.Fatal("defaults should list something")
	}
	m := relPaths(entries)
	if _, ok := m["d1/d2/d3/d4/d5"]; ok {
		t.Fatalf("default depth (4) not applied: %v", m)
	}
}

func TestBuildTreeListDoesNotFollowSymlinkDirs(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks")
	}
	root := mkTree(t)
	if err := os.Symlink(filepath.Join(root, "a"), filepath.Join(root, "loop")); err != nil {
		t.Fatal(err)
	}
	entries, _ := buildTreeList(root, fileFetchRequest{Depth: 6, MaxEntries: 100})
	m := relPaths(entries)
	if m["loop"] {
		t.Fatalf("symlink should not be a dir entry: %v", m)
	}
	if _, ok := m["loop/b"]; ok {
		t.Fatalf("symlink dir was followed: %v", m)
	}
}

func TestBuildTreeListSuffixSkip(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "dd.noindex/deep"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "dd.noindex/deep/x.o"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	entries, _ := buildTreeList(root, fileFetchRequest{Skip: []string{"*.noindex"}})
	m := relPaths(entries)
	if _, ok := m["dd.noindex"]; !ok {
		t.Fatalf("suffix-skipped dir should still be listed: %v", m)
	}
	if _, ok := m["dd.noindex/deep"]; ok {
		t.Fatalf("suffix skip not pruned: %v", m)
	}
}

func TestBuildTreeListPerDirChildCap(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "flat"), 0o755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 30; i++ {
		name := filepath.Join(root, "flat", "f"+string(rune('a'+i%26))+string(rune('0'+i/26))+".txt")
		if err := os.WriteFile(name, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "zz"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "zz/real.go"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	entries, truncated := buildTreeList(root, fileFetchRequest{MaxChildren: 5})
	if !truncated {
		t.Fatal("expected truncation flag")
	}
	m := relPaths(entries)
	flat := 0
	for p := range m {
		if len(p) > 5 && p[:5] == "flat/" {
			flat++
		}
	}
	if flat != 5 {
		t.Fatalf("want 5 flat children, got %d", flat)
	}
	if _, ok := m["zz/real.go"]; !ok {
		t.Fatalf("sibling starved by flat dir: %v", m)
	}
}

func TestResolveFetchPathList(t *testing.T) {
	// The list op reuses resolveFetchPath — relative roots against cwd.
	got, err := resolveFetchPath(".", "/tmp/somewhere")
	if err != nil || got != "/tmp/somewhere" {
		t.Fatalf("got %q err %v", got, err)
	}
	if _, err := resolveFetchPath("rel", ""); err == nil {
		t.Fatal("relative root with no cwd must fail")
	}
}
