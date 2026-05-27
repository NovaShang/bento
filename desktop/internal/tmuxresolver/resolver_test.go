package tmuxresolver

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestParseVersion(t *testing.T) {
	cases := []struct {
		in   string
		want Version
	}{
		{"tmux 3.5a\n", Version{3, 5, "a"}},
		{"tmux 3.5\n", Version{3, 5, ""}},
		{"tmux 2.6\n", Version{2, 6, ""}},
		{"tmux next-3.6\n", Version{3, 6, ""}},
		{"tmux openbsd-3.4", Version{3, 4, ""}},
		{"garbage", Version{}},
		{"", Version{}},
	}
	for _, c := range cases {
		got := ParseVersion(c.in)
		if got != c.want {
			t.Errorf("ParseVersion(%q) = %+v, want %+v", c.in, got, c.want)
		}
	}
}

func TestAtLeast(t *testing.T) {
	cases := []struct {
		a, b Version
		want bool
	}{
		{Version{3, 5, "a"}, Version{3, 2, ""}, true},
		{Version{3, 2, ""}, Version{3, 2, ""}, true},
		{Version{3, 2, "a"}, Version{3, 2, ""}, true},
		{Version{3, 1, "c"}, Version{3, 2, ""}, false},
		{Version{2, 9, ""}, Version{3, 2, ""}, false},
		{Version{4, 0, ""}, Version{3, 9, ""}, true},
	}
	for _, c := range cases {
		if got := c.a.AtLeast(c.b); got != c.want {
			t.Errorf("%s.AtLeast(%s) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

// fakeTmux writes a tiny shell script that prints the given version when
// invoked with `-V`. Used to drive Resolve without a real tmux on the host.
func fakeTmux(t *testing.T, dir, version string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fakes are POSIX-only")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "tmux")
	body := "#!/bin/sh\necho 'tmux " + version + "'\n"
	if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestResolveOverride(t *testing.T) {
	tmp := t.TempDir()
	override := fakeTmux(t, filepath.Join(tmp, "override"), "3.5a")
	res, err := Resolve(Options{
		Env:               func(k string) string { if k == "BENTO_TMUX" { return override }; return "" },
		SystemSearchPaths: []string{}, // pretend no system tmux
		BundledSearchDirs: []string{},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Kind != KindOverride || res.Path != override {
		t.Fatalf("got %+v, want override at %s", res, override)
	}
}

func TestResolvePrefersSystem(t *testing.T) {
	tmp := t.TempDir()
	sys := fakeTmux(t, filepath.Join(tmp, "sys"), "3.5a")
	_ = fakeTmux(t, filepath.Join(tmp, "bundled"), "3.4")
	res, err := Resolve(Options{
		Env:               func(string) string { return "" },
		SystemSearchPaths: []string{sys},
		BundledSearchDirs: []string{filepath.Join(tmp, "bundled")},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Kind != KindSystem || res.Path != sys {
		t.Fatalf("got %+v, want system at %s", res, sys)
	}
}

func TestResolveFallsBackOnOldSystem(t *testing.T) {
	tmp := t.TempDir()
	sys := fakeTmux(t, filepath.Join(tmp, "sys"), "2.6")
	bundledDir := filepath.Join(tmp, "bundled")
	bundled := fakeTmux(t, bundledDir, "3.5a")
	res, err := Resolve(Options{
		Env:               func(string) string { return "" },
		SystemSearchPaths: []string{sys},
		BundledSearchDirs: []string{bundledDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Kind != KindBundled || res.Path != bundled {
		t.Fatalf("got %+v, want bundled at %s", res, bundled)
	}
	if res.Reason == "" {
		t.Errorf("expected non-empty reason explaining the fallback")
	}
}

func TestResolveErrorsWhenNothingAvailable(t *testing.T) {
	_, err := Resolve(Options{
		Env:               func(string) string { return "" },
		SystemSearchPaths: []string{"/nonexistent/tmux"},
		BundledSearchDirs: []string{"/nonexistent/dir"},
	})
	if err == nil {
		t.Fatal("expected error when no tmux available")
	}
}
