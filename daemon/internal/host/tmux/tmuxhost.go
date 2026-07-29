// Package tmuxhost is the daemon-side tmux host layer
// (docs/tmux-host-design.md §分层): one control-mode client per tmux server
// target, owning every goroutine and lock that internal/tmuxcm — a
// deliberately synchronous state machine — refuses to carry.
//
// What it surfaces to the layer above (acphost, which wraps panes into
// virtual instances):
//
//   - EnsureLocal: bring up (or adopt) the ONE `tmux -CC` control client for
//     the local target, and make the named session exist and be that
//     client's current session (attach-or-create — the same
//     `new-session -A` semantics the frozen product typed into a shell).
//     One client per TARGET, any number of sessions behind it.
//   - a server-wide structure snapshot (sessions ⊃ windows ⊃ panes) rebuilt
//     on %sessions-changed/%session-*/%window-*/%unlinked-window-*/
//     %layout-change notifications and delivered through the OnStructure
//     callback — the feed the statekv mirror in acphost is built from
//     (design doc §结构镜像).
//   - per-pane output subscriptions (%output, octal escapes already
//     decoded) and WritePane (send-keys -H, so any byte survives tmux's
//     parser). NOTE: tmux only streams %output for panes of the client's
//     CURRENT session; ensure switches the client, so the last-ensured
//     session is the streaming one.
//
// Socket policy: the local target speaks to the DEFAULT tmux server socket —
// the same server `tmux` in the user's terminal talks to, so the daemon sees
// the user's real sessions and the user sees the daemon's. The only override
// is the BENTO_TMUX_SOCKET environment variable (a `-L` socket name), which
// exists for tests and development ONLY — nothing in production wiring may
// pin a private socket; that exact mistake once hid the user's entire tmux
// world behind a daemon-private twin. $BENTO_TMUX keeps overriding the
// binary path as before.
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
// machine, over the default server socket (see the socket policy above).
const LocalTarget = "local"

// socketEnv names the ONLY socket override: a `-L` socket name for tests
// and development. Empty (the production case) = the default tmux server.
const socketEnv = "BENTO_TMUX_SOCKET"

// resolveSocket reads the test/dev socket override. "" = default server.
func resolveSocket() string { return os.Getenv(socketEnv) }

// ensureTimeout bounds EnsureLocal: launching may include starting the tmux
// server itself, and a hung launch must fail the spawn, not wedge it.
const ensureTimeout = 20 * time.Second

// SessionStructure is one session's row in a target's server-wide structure
// snapshot: identity ($N id — rename-stable — plus current name) and the
// session's windows ⊃ panes tree.
type SessionStructure struct {
	ID   string                   `json:"id"` // tmux session id, "$N"
	Name string                   `json:"name"`
	Snap tmuxcm.StructureSnapshot `json:"structure"`
}

// Config configures the host. The zero value is production: resolved tmux,
// the default server socket, the user's own tmux config.
type Config struct {
	// TmuxPath pins the tmux binary. "" = resolve: $BENTO_TMUX, then the
	// bundled helper next to the daemon binary, then PATH / well-known
	// locations (see resolveTmux).
	TmuxPath string
	// ConfigFile is a -f override; "" = the user's own tmux config. Tests
	// pass /dev/null (or a fixture) for determinism.
	//
	// There is deliberately NO socket field: the socket is the default
	// server, overridable only via $BENTO_TMUX_SOCKET (tests/dev) — see the
	// package comment's socket policy.
	ConfigFile string
	// OnStructure is invoked whenever a target's server-wide structure
	// snapshot changes, including the initial one taken during ensure —
	// EnsureLocal does not return before that first delivery has completed,
	// so the caller's mirror is in place before it acks. currentSession is
	// the control client's current session (the one whose panes stream
	// %output). Called from the client's own refresher goroutine, never
	// concurrently for one target.
	OnStructure func(target, currentSession string, sessions []SessionStructure)
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
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	return &Host{cfg: cfg, clients: make(map[string]*Client)}
}

// EnsureLocal brings up (or adopts) the local target's control client and
// makes `session` exist and be its current session, returning once the
// session exists, the greeting has been consumed, and a structure snapshot
// including the session has been delivered.
//
// Launch is single-flight by construction: h.mu is held across the
// existing-client check AND launchLocal, so two racing ensures can never
// start two `tmux -CC` processes — the loser of the lock finds the winner's
// client in the map and adopts it (awaitReady is level-based, so both see
// the same readiness edge). The per-session step (create-if-missing +
// switch-client) is serialized separately on the client's own ensure lock.
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
	launched := false
	if c == nil {
		var err error
		c, err = launchLocal(h.cfg, session)
		if err != nil {
			h.mu.Unlock()
			return nil, err
		}
		h.clients[LocalTarget] = c
		launched = true
	}
	h.mu.Unlock()

	// Outside h.mu: readiness can take seconds, and a concurrent ensure for
	// the same target should adopt the launching client and wait alongside
	// us (awaitReady is level-based, so both callers see the same edge).
	if err := c.awaitReady(ensureTimeout); err != nil {
		c.Close()
		h.dropIf(c)
		return nil, err
	}
	if launched {
		// The launch line itself was `new-session -A -s <session>` — the
		// session exists and is current, and the first snapshot (which
		// awaitReady just gated on) already lists every session on the
		// server.
		return c, nil
	}
	// Adopt path: the shared client is up; attach-or-create the session on
	// it (idempotent, serialized per client) and barrier so the mirror
	// includes it before the caller acks.
	if err := c.EnsureSession(session); err != nil {
		if c.isDead() {
			// The server went away under the ensure (e.g. its last session
			// was killed): drop the corpse so the next ensure relaunches.
			h.dropIf(c)
		}
		return nil, err
	}
	return c, nil
}

// dropIf removes a specific client from the registry if it is still the
// registered one — never a successor that raced in.
func (h *Host) dropIf(c *Client) {
	h.mu.Lock()
	if h.clients[LocalTarget] == c {
		delete(h.clients, LocalTarget)
	}
	h.mu.Unlock()
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
