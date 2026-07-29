// Package tmuxhost is the daemon-side tmux host layer
// (docs/tmux-host-design.md §分层): one control-mode client per tmux server
// target, owning every goroutine and lock that internal/tmuxcm — a
// deliberately synchronous state machine — refuses to carry.
//
// What it surfaces to the layer above (acphost, which wraps panes into
// virtual instances):
//
//   - EnsureLocal: bring up (or adopt) the `tmux -CC` control client for a
//     target+session. The launch line is tmuxcm.LaunchCommand's
//     `new-session -A`, so "ensure" is true at the tmux level too: attach
//     when the session exists, create when it doesn't, never a second one.
//   - a structure snapshot (windows ⊃ panes) rebuilt on
//     %layout-change/%window-*/%session-* notifications and delivered
//     through the OnStructure callback — the feed the statekv mirror in
//     acphost is built from (design doc §结构镜像).
//   - per-pane output subscriptions (%output, octal escapes already
//     decoded) and WritePane (send-keys -H, so any byte survives tmux's
//     parser).
//
// Dependency direction is acphost → tmuxhost → tmuxcm; nothing here may
// import acphost.
//
// v1 is local-only. An ssh:// target would exec `ssh host -- tmux -CC`
// instead of a local pty and change nothing else here — the seam is
// launchLocal (design doc §远程).
package tmuxhost

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
	"unicode"

	"github.com/novashang/bento/daemon/internal/tmuxcm"
)

// LocalTarget is the one target v1 supports: tmux on the daemon's own
// machine, over a private -L socket.
const LocalTarget = "local"

// ensureTimeout bounds EnsureLocal: launching may include starting the tmux
// server itself, and a hung launch must fail the spawn, not wedge it.
const ensureTimeout = 20 * time.Second

// Config configures the host. The zero value is production: resolved tmux,
// socket "bento-acp", the user's own tmux config.
type Config struct {
	// TmuxPath pins the tmux binary. "" = resolve: $BENTO_TMUX, then the
	// bundled helper next to the daemon binary, then PATH / well-known
	// locations (see resolveTmux).
	TmuxPath string
	// SocketName is the private `tmux -L` socket the daemon's sessions live
	// on. "" = "bento-acp". Tests use a throwaway name so they can never
	// touch a real server.
	SocketName string
	// ConfigFile is a -f override; "" = the user's own tmux config. Tests
	// pass /dev/null (or a fixture) for determinism.
	ConfigFile string
	// OnStructure is invoked whenever a target's structure snapshot changes,
	// including the initial one taken during ensure — EnsureLocal does not
	// return before that first delivery has completed, so the caller's
	// mirror is in place before it acks. Called from the client's own
	// refresher goroutine, never concurrently for one target.
	OnStructure func(target, session string, snap tmuxcm.StructureSnapshot)
	// Logf receives send/receive tracing and warnings. nil = silent.
	Logf func(format string, args ...any)
}

// Host owns the control clients, one per target.
type Host struct {
	cfg Config

	mu      sync.Mutex
	clients map[string]*Client
}

// New builds a host. Nothing is launched until the first ensure — a daemon
// that is never asked for tmux never runs one.
func New(cfg Config) *Host {
	if cfg.SocketName == "" {
		cfg.SocketName = "bento-acp"
	}
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	return &Host{cfg: cfg, clients: make(map[string]*Client)}
}

// EnsureLocal brings up (or adopts) the control client for the local
// target's `session`, returning once the session exists, the greeting has
// been consumed, and the first structure snapshot has been delivered.
//
// One session per target for now: a second name refuses loudly rather than
// silently switching the client (switch-client re-plumbing is a later
// step, alongside ssh targets).
func (h *Host) EnsureLocal(session string) (*Client, error) {
	if !validSessionName(session) {
		return nil, fmt.Errorf("tmux ensure: invalid session name %q", session)
	}
	h.mu.Lock()
	c := h.clients[LocalTarget]
	if c != nil && c.isDead() {
		// The previous client died (tmux server gone, or the process was
		// killed). The session may well still exist — relaunching with -A
		// adopts it.
		delete(h.clients, LocalTarget)
		c = nil
	}
	if c != nil && c.sessionName() != session {
		name := c.sessionName()
		h.mu.Unlock()
		return nil, fmt.Errorf(
			"tmux target %q already manages session %q; one session per target until the multi-session step",
			LocalTarget, name)
	}
	if c == nil {
		var err error
		c, err = launchLocal(h.cfg, session)
		if err != nil {
			h.mu.Unlock()
			return nil, err
		}
		h.clients[LocalTarget] = c
	}
	h.mu.Unlock()

	// Outside h.mu: readiness can take seconds, and a concurrent ensure for
	// the same target should adopt the launching client and wait alongside
	// us (awaitReady is level-based, so both callers see the same edge).
	if err := c.awaitReady(ensureTimeout); err != nil {
		c.Close()
		h.mu.Lock()
		if h.clients[LocalTarget] == c {
			delete(h.clients, LocalTarget)
		}
		h.mu.Unlock()
		return nil, err
	}
	return c, nil
}

// Client returns the live control client for a target, nil when none has
// been ensured (or the last one died).
func (h *Host) Client(target string) *Client {
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.clients[target]
	if c == nil || c.isDead() {
		return nil
	}
	return c
}

// Close tears down every control client. The tmux servers and their panes
// stay — detaching a client never kills a session; that is the product.
func (h *Host) Close() {
	h.mu.Lock()
	clients := make([]*Client, 0, len(h.clients))
	for _, c := range h.clients {
		clients = append(clients, c)
	}
	h.clients = make(map[string]*Client)
	h.mu.Unlock()
	for _, c := range clients {
		c.Close()
	}
}

// resolveTmux picks the binary. Order (the acp daemon's policy — bundled
// before system, unlike the frozen terminal product which preferred the
// user's own tmux): an explicit pin, $BENTO_TMUX, the bundled helper
// staged next to the daemon binary (the Mac app puts both under
// Contents/MacOS/helpers), then PATH, then the well-known install
// locations — launchd hands the daemon a minimal PATH that misses
// Homebrew, the same reason acphost.augmentedEnv exists.
func resolveTmux(explicit string) (string, error) {
	if explicit != "" {
		return explicit, nil // trust the pin; exec will fail loudly if bogus
	}
	if p := os.Getenv("BENTO_TMUX"); p != "" && isExecutable(p) {
		return p, nil
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		for _, cand := range []string{
			filepath.Join(dir, "tmux"),
			filepath.Join(dir, "helpers", "tmux"),
		} {
			if isExecutable(cand) {
				return cand, nil
			}
		}
	}
	if p, err := exec.LookPath("tmux"); err == nil {
		return p, nil
	}
	for _, p := range []string{"/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"} {
		if isExecutable(p) {
			return p, nil
		}
	}
	return "", errors.New("tmux not found: no bundled helper next to the daemon and none on PATH")
}

func isExecutable(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir() && info.Mode().Perm()&0o111 != 0
}

// validSessionName accepts letters, digits, '-' and '_': the intersection
// of what tmux allows (':' and '.' are target syntax) and what
// tmuxcm.LaunchCommand splices into the launch line unquoted.
func validSessionName(name string) bool {
	if name == "" {
		return false
	}
	for _, r := range name {
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) && r != '-' && r != '_' {
			return false
		}
	}
	return true
}
