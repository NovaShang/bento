// Package tmuxresolver locates the tmux binary the daemon should use to
// spawn control-mode sessions for paired iOS clients.
//
// Policy: prefer the user's own tmux (so security updates from brew/apt
// reach us, and so power users can keep their patched build), but fall
// back to a bundled binary shipped next to bento-daemon when the system
// tmux is missing or too old.
//
// The minimum version (3.2) is the oldest tmux release where `-CC` control
// mode is reliable enough for Bento — older versions have known issues
// with notification framing that we hit during early prototyping.
package tmuxresolver

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// MinVersion is the lowest tmux release we accept as "system". Anything
// older silently falls back to the bundled binary.
var MinVersion = Version{Major: 3, Minor: 2}

// Kind tags how the resolved binary was found, surfaced to UIs/logs.
type Kind string

const (
	KindSystem   Kind = "system"   // found on PATH / well-known locations
	KindBundled  Kind = "bundled"  // shipped next to bento-daemon
	KindOverride Kind = "override" // $BENTO_TMUX
)

// Resolution is the full picture of which tmux we picked and why.
type Resolution struct {
	Path    string  `json:"path"`
	Version Version `json:"version"`
	Kind    Kind    `json:"kind"`
	// Reason is a short human-readable note like "system tmux 3.5a" or
	// "bundled (system tmux 3.1 < required 3.2)". Surfaced in `bento doctor`.
	Reason string `json:"reason"`
}

// Version is parsed from `tmux -V` output (e.g. "tmux 3.5a" → 3.5, suffix "a").
type Version struct {
	Major  int    `json:"major"`
	Minor  int    `json:"minor"`
	Suffix string `json:"suffix,omitempty"` // letter suffix like "a"
}

func (v Version) String() string {
	if v.Major == 0 && v.Minor == 0 {
		return "unknown"
	}
	return fmt.Sprintf("%d.%d%s", v.Major, v.Minor, v.Suffix)
}

// AtLeast returns true if v is >= other. Suffix is treated as a tiebreaker
// (3.2a > 3.2), but we never compare suffix below the major.minor floor.
func (v Version) AtLeast(other Version) bool {
	if v.Major != other.Major {
		return v.Major > other.Major
	}
	if v.Minor != other.Minor {
		return v.Minor > other.Minor
	}
	return v.Suffix >= other.Suffix
}

// ParseVersion parses the output of `tmux -V` ("tmux 3.5a\n" → {3,5,"a"}).
// Returns zero-value Version on parse failure rather than error: callers
// should treat unknown versions as "too old" and fall back to bundled.
func ParseVersion(out string) Version {
	out = strings.TrimSpace(out)
	out = strings.TrimPrefix(out, "tmux ")
	// Some forks prefix differently — take the last whitespace-separated token.
	if i := strings.LastIndex(out, " "); i >= 0 {
		out = out[i+1:]
	}
	// Strip leading non-digit chars so "next-3.6" / "openbsd-3.4" parse.
	for len(out) > 0 && (out[0] < '0' || out[0] > '9') {
		out = out[1:]
	}
	dot := strings.Index(out, ".")
	if dot <= 0 {
		return Version{}
	}
	major, err := strconv.Atoi(out[:dot])
	if err != nil {
		return Version{}
	}
	rest := out[dot+1:]
	// Walk digits; remainder is the suffix.
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {
		end++
	}
	if end == 0 {
		return Version{}
	}
	minor, err := strconv.Atoi(rest[:end])
	if err != nil {
		return Version{}
	}
	return Version{Major: major, Minor: minor, Suffix: rest[end:]}
}

// Options tunes resolution. Zero value is fine — defaults match daemon use.
type Options struct {
	// BundledSearchDirs is the list of directories to probe for a bundled
	// tmux when system tmux is missing/too old. If empty, defaults to:
	//   <dir of current executable>, <dir>/helpers, ~/.bento/bin
	BundledSearchDirs []string

	// SystemSearchPaths is the list of absolute paths to probe before
	// falling back to $PATH lookup. If empty, defaults to the macOS
	// Homebrew + system paths.
	SystemSearchPaths []string

	// Env is the environment lookup (defaults to os.Getenv). Tests override.
	Env func(string) string
}

// Resolve picks the tmux binary to use. Returns an error only when neither
// system nor bundled tmux is available — in that case the caller should
// surface the install hint to the user.
func Resolve(opt Options) (Resolution, error) {
	if opt.Env == nil {
		opt.Env = os.Getenv
	}

	// 1. Explicit override always wins. Validate it's actually executable
	//    so a stale BENTO_TMUX in the user's shell doesn't silently break
	//    everything — fall through to normal resolution if it's bogus.
	if p := opt.Env("BENTO_TMUX"); p != "" {
		if v, ok := probeVersion(p); ok {
			return Resolution{Path: p, Version: v, Kind: KindOverride,
				Reason: "BENTO_TMUX=" + p}, nil
		}
	}

	// Explicit SystemSearchPaths (even empty) means "use exactly this list";
	// nil means "use defaults AND fall back to $PATH lookup". This split lets
	// tests pin the search space without leaking the host's real tmux in.
	useDefaults := opt.SystemSearchPaths == nil
	systemPaths := opt.SystemSearchPaths
	if useDefaults {
		systemPaths = defaultSystemPaths()
	}

	// 2. System tmux at well-known locations.
	var sysPath string
	var sysVer Version
	for _, p := range systemPaths {
		if v, ok := probeVersion(p); ok {
			sysPath, sysVer = p, v
			break
		}
	}
	// 3. Fall back to $PATH lookup if not in the canonical list (defaults only).
	if sysPath == "" && useDefaults {
		if p, err := exec.LookPath("tmux"); err == nil {
			if v, ok := probeVersion(p); ok {
				sysPath, sysVer = p, v
			}
		}
	}

	// 4. If we have a recent enough system tmux, use it.
	if sysPath != "" && sysVer.AtLeast(MinVersion) {
		return Resolution{Path: sysPath, Version: sysVer, Kind: KindSystem,
			Reason: "system tmux " + sysVer.String()}, nil
	}

	// 5. Bundled fallback.
	bundledDirs := opt.BundledSearchDirs
	if bundledDirs == nil {
		bundledDirs = defaultBundledDirs()
	}
	for _, dir := range bundledDirs {
		p := filepath.Join(dir, "tmux")
		if v, ok := probeVersion(p); ok {
			reason := "bundled tmux " + v.String()
			if sysPath != "" {
				// Tell the user *why* we ignored their system tmux.
				reason = fmt.Sprintf("bundled tmux %s (system %s is older than %s)",
					v.String(), sysVer.String(), MinVersion.String())
			}
			return Resolution{Path: p, Version: v, Kind: KindBundled,
				Reason: reason}, nil
		}
	}

	// 6. Nothing worked. Hand the caller a hint they can show the user.
	if sysPath != "" {
		return Resolution{}, fmt.Errorf(
			"tmux %s found at %s but bento requires >= %s; bundled tmux not present (reinstall bento, or upgrade tmux)",
			sysVer.String(), sysPath, MinVersion.String())
	}
	return Resolution{}, errors.New(
		"tmux not found. install with `brew install tmux` (macOS) or `apt install tmux` (Debian/Ubuntu), or reinstall bento to get the bundled binary")
}

// probeVersion runs `<path> -V` and parses the output. Returns ok=false if
// the path isn't executable or doesn't look like tmux.
func probeVersion(path string) (Version, bool) {
	if path == "" {
		return Version{}, false
	}
	info, err := os.Stat(path)
	if err != nil || info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return Version{}, false
	}
	out, err := exec.Command(path, "-V").Output()
	if err != nil {
		return Version{}, false
	}
	v := ParseVersion(string(out))
	if v.Major == 0 && v.Minor == 0 {
		return Version{}, false
	}
	return v, true
}

func defaultSystemPaths() []string {
	return []string{
		"/opt/homebrew/bin/tmux", // Apple Silicon Homebrew
		"/usr/local/bin/tmux",    // Intel Homebrew / Linux /usr/local
		"/usr/bin/tmux",          // distro packages, macOS system (none on stock)
	}
}

// defaultBundledDirs returns the directories to probe for a bundled tmux,
// in priority order. They all sit close to the running daemon binary so
// a single install (or app bundle) keeps everything together.
func defaultBundledDirs() []string {
	var dirs []string
	if exe, err := os.Executable(); err == nil {
		d := filepath.Dir(exe)
		dirs = append(dirs, d, filepath.Join(d, "helpers"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, ".bento", "bin"))
	}
	return dirs
}
