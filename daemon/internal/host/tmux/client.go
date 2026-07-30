package tmuxhost

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/novashang/bento/daemon/internal/tmuxcm"
)

// A control client's declared size. tmux derives window sizes from its
// clients (window-size latest by default), and a pty nobody sized would
// clamp every window to its 0×0; this default holds until a stream declares
// a viewport — it is what ResolveGoverningSize (sizing.go) answers when no
// declarations exist.
const (
	defaultCols = 200
	defaultRows = 50
)

// Client is one target's live control-mode connection: the `tmux -CC`
// process on its pty, the goroutines that pump it, and the current
// server-wide structure snapshot (every session, not just the one the
// client is attached to).
type Client struct {
	target      string
	logf        func(string, ...any)
	onStructure func(target, currentSession string, sessions []SessionStructure)

	// mu guards cm (tmuxcm is deliberately synchronous: every Feed and every
	// Send happens under this lock), the snapshot, the session identity and
	// the subscription table. Callbacks out of cm fire under mu and therefore
	// do only cheap state updates and channel signals; anything that can
	// block — subscriber delivery, the structure mirror — runs on its own
	// goroutine.
	mu   sync.Mutex
	cm   *tmuxcm.ControlMode
	proc *exec.Cmd
	ptmx *os.File
	// session/sessionID are the client's CURRENT session (the one whose
	// panes stream %output): name tracks %session-changed/%session-renamed
	// live; the id ($N) is rename-stable and is what refreshes reconcile the
	// name against. sessionID is "" until the first %session-changed (or the
	// first refresh matches by name).
	session   string
	sessionID string
	dead      bool
	deadErr   error
	ready     bool
	preReady  []byte // raw output before the greeting, kept for error reports
	sessions  []SessionStructure
	snapJSON  []byte
	subs      map[tmuxcm.PaneID]*paneSub
	// sizing is the daemon-resolved size-authority block (SetSizing). Kept
	// here so it participates in structure CHANGE DETECTION: a policy/owner
	// change with an unchanged window shape must still republish the mirror,
	// and the refresher goroutine's compare-and-publish is the one gate every
	// mirror write passes through.
	sizing Sizing

	// ensureMu serializes EnsureSession (the per-session attach-or-create
	// step): two racing ensures for the same missing session must not both
	// run `new-session -d`. A leaf above mu — EnsureSession never holds it
	// while mu is held, only across Exec/Barrier calls.
	ensureMu sync.Mutex

	// refreshCh coalesces structure-refresh requests (buffered 1: a burst of
	// %layout-change during a refresh collapses into one follow-up).
	refreshCh chan struct{}
	// syncCh carries Barrier requests: the refresher goroutine runs one FULL
	// refresh pass (listings issued after the request, delivery included)
	// and closes the reply channel — the "read path now shows what you just
	// wrote" edge the structure op's ack is built on.
	syncCh chan chan struct{}
	// firstSnap latches once the first snapshot has been delivered through
	// OnStructure — the gate EnsureLocal waits behind. Also closed by
	// teardown so a client that dies before ready releases its waiters.
	firstSnap chan struct{}
	firstOnce sync.Once
	done      chan struct{}
}

// launchShellLine builds the `/bin/sh -c` line that launches the control
// client: the resolved binary, -u, the socket flag (ONLY when a test/dev
// override names one — production runs against the default server, see the
// package comment's socket policy), the -f override, and
// tmuxcm.LaunchCommand's `new-session -A` ensure line. Pure so the
// socket-policy guard test can pin the default-vs-override choice without
// ever connecting to a server.
//
// -u is load-bearing: the daemon is a launchd job, so this client's
// environment has no LC_ALL/LC_CTYPE/LANG. Without -u tmux flags the client
// non-UTF-8 and utf8_sanitize()s every format expansion it serves — each
// wide char in list-panes/list-windows output (pane_title, window_name)
// comes back as per-column underscores ("中文" → "____"). A user terminal
// always had a UTF-8 locale, which is why the frozen product never hit it.
func launchShellLine(bin, socket, configFile, session string) string {
	launch := strings.TrimPrefix(
		strings.TrimSuffix(tmuxcm.LaunchCommand(session, "", "", ""), "\n"), "tmux")
	line := "exec " + tmuxcm.ShellQuoteArg(bin) + " -u"
	if socket != "" {
		line += " -L " + tmuxcm.ShellQuoteArg(socket)
	}
	if configFile != "" {
		line += " -f " + tmuxcm.ShellQuoteArg(configFile)
	}
	return line + launch
}

// launchLocal execs `tmux -CC` for a local target. Two facts shape the how:
//
//   - The command line is tmuxcm.LaunchCommand's — the same `new-session -A`
//     ensure line the frozen product types into a shell — with the resolved
//     binary (and, under a test override only, a -L socket) spliced in
//     front. Reusing it keeps the create-or-attach semantics in ONE place.
//   - tmux -CC insists on a tty (tcgetattr on stdin) even though control
//     mode is line-oriented; over plain pipes it dies with "tcgetattr
//     failed" before attaching (verified live, and the reason tmuxcm's live
//     tests attach through /usr/bin/script). So the client lives on a pty.
//
// ps note: when no server runs yet, this ONE client forks the tmux server,
// which daemonizes (daemon(3): a double fork — the intermediate pid dies)
// and on macOS keeps the client's argv (setproctitle is a no-op there). Two
// processes with the same `-CC new-session -A` line and pids two apart are
// therefore the client AND ITS SERVER, not two clients — the launch itself
// is single-flight under Host.mu.
func launchLocal(cfg Config, session string) (*Client, error) {
	bin, err := resolveTmux(cfg.TmuxPath)
	if err != nil {
		return nil, err
	}
	shellLine := launchShellLine(bin, resolveSocket(), cfg.ConfigFile, session)

	cmd := exec.Command("/bin/sh", "-c", shellLine)
	c := &Client{
		target:      LocalTarget,
		logf:        cfg.Logf,
		onStructure: cfg.OnStructure,
		session:     session,
		sizing:      DefaultSizing(),
		subs:        make(map[tmuxcm.PaneID]*paneSub),
		refreshCh:   make(chan struct{}, 1),
		syncCh:      make(chan chan struct{}),
		firstSnap:   make(chan struct{}),
		done:        make(chan struct{}),
	}
	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("launch tmux control client: %w", err)
	}
	_ = pty.Setsize(ptmx, &pty.Winsize{Rows: defaultRows, Cols: defaultCols})
	c.proc = cmd
	c.ptmx = ptmx
	c.cm = &tmuxcm.ControlMode{
		OnNotification: c.handleNotification,
		Write: func(line string) {
			_, _ = io.WriteString(ptmx, line)
		},
		OnReady: func() { // under c.mu (fires inside Feed)
			c.ready = true
			// Declare a size — the pty's own says nothing useful — and take
			// the first structure snapshot. The sizing block's size, not a
			// bare constant: a SetSizing that raced the greeting (a stream
			// declared its viewport before the ensure finished) must not be
			// overwritten by the launch default.
			c.cm.SendFireAndForget(tmuxcm.RefreshClient(c.sizing.Cols, c.sizing.Rows))
			c.requestRefreshLocked()
		},
		Logf: cfg.Logf,
	}

	go c.readLoop()
	go c.refreshLoop()
	go func() {
		werr := cmd.Wait()
		if werr != nil {
			c.teardown(fmt.Errorf("tmux control client exited: %w", werr))
		} else {
			c.teardown(errors.New("tmux control client exited"))
		}
	}()
	return c, nil
}

// awaitReady blocks until the first structure snapshot has been published
// (EnsureLocal must not return before the caller's mirror is in place — the
// caller acks the ensure, and a getstate racing that ack must not read
// empty) or the client dies.
func (c *Client) awaitReady(timeout time.Duration) error {
	select {
	case <-c.firstSnap:
	case <-time.After(timeout):
		return fmt.Errorf("tmux control client for %s: not ready after %s", c.target, timeout)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dead {
		return c.deadErr
	}
	return nil
}

func (c *Client) isDead() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.dead
}

// WaitClosed blocks until the client is fully torn down (or the timeout
// passes). The killSession-of-the-last-session path uses it: the kill takes
// the whole server — and this client — down, and the empty-server mirror
// must not be published while a live refresher could still race it.
func (c *Client) WaitClosed(timeout time.Duration) bool {
	select {
	case <-c.done:
		return true
	case <-time.After(timeout):
		return false
	}
}

func (c *Client) sessionName() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.session
}

// Structure returns the current server-wide snapshot: one row per session,
// in list-sessions order. Treat it as read-only: refreshes replace it
// wholesale, never mutate it.
func (c *Client) Structure() []SessionStructure {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.sessions
}

// SessionName is the control client's CURRENT session — the one whose panes
// stream %output — tracking renames/switches live (%session-renamed /
// %session-changed, reconciled by session id on every refresh).
func (c *Client) SessionName() string { return c.sessionName() }

// Exec sends one tmux command and waits for its response block. This is the
// structure-verb write path: the caller inspects IsError (tmux refused) and
// then Barriers for the mirror to catch up. The error return is transport
// death or a wedged tmux, never a tmux-level refusal.
func (c *Client) Exec(cmd tmuxcm.Command) (tmuxcm.CommandResponse, error) {
	ch := make(chan tmuxcm.CommandResponse, 1)
	c.mu.Lock()
	if c.dead {
		err := c.deadErr
		c.mu.Unlock()
		return tmuxcm.CommandResponse{}, fmt.Errorf("tmux control client for %s is gone: %v", c.target, err)
	}
	if !c.ready {
		c.mu.Unlock()
		return tmuxcm.CommandResponse{}, fmt.Errorf("tmux control client for %s not ready", c.target)
	}
	c.cm.Send(cmd, func(r tmuxcm.CommandResponse) { ch <- r })
	c.mu.Unlock()
	r, ok := c.awaitResponse(ch)
	if !ok {
		return tmuxcm.CommandResponse{}, fmt.Errorf("tmux command timed out or client died: %s", cmd)
	}
	return r, nil
}

// Barrier waits for one full structure-refresh pass that STARTED after the
// call: its listings are issued after every command the caller already got a
// response for (same connection, tmux executes in order), and its OnStructure
// delivery — the statekv mirror write in acphost — has completed by the time
// Barrier returns. That is exactly the "rev N includes the verb's effect"
// promise structureApplied makes.
func (c *Client) Barrier(timeout time.Duration) error {
	done := make(chan struct{})
	select {
	case c.syncCh <- done:
	case <-c.done:
		return fmt.Errorf("tmux control client for %s is gone", c.target)
	case <-time.After(timeout):
		return fmt.Errorf("tmux structure barrier for %s: refresher busy after %s", c.target, timeout)
	}
	select {
	case <-done:
		return nil
	case <-c.done:
		return fmt.Errorf("tmux control client for %s is gone", c.target)
	case <-time.After(timeout):
		return fmt.Errorf("tmux structure barrier for %s: no refresh after %s", c.target, timeout)
	}
}

// SetSizing installs the daemon-resolved size-authority block (docs/
// tmux-host-design.md 步骤 5.5). Two effects, one call, in one order:
//
//  1. the governing size is declared to tmux (`refresh-client -C`) on THIS
//     connection, so any Barrier the caller runs next lists a world where
//     tmux has already processed the declaration (same connection, in-order
//     execution — the property every structure ack is built on);
//  2. the block joins structure change detection (see refreshStructure) and
//     a refresh is requested, so the mirror republishes even when the
//     declaration changed nothing tmux would notify about (a policy or
//     owner-label change at an unchanged size).
//
// Pre-ready the block is only stored: OnReady declares c.sizing itself, so
// the declaration is never lost, merely deferred to the greeting.
func (c *Client) SetSizing(s Sizing) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dead {
		return
	}
	c.sizing = s
	if c.ready {
		c.cm.SendFireAndForget(tmuxcm.RefreshClient(s.Cols, s.Rows))
	}
	c.requestRefreshLocked()
}

// ListSessions takes a FRESH `list-sessions` reading (never the cached
// snapshot) — what EnsureSession and the killSession verb decide on, so a
// decision made right after another write sees that write's world.
func (c *Client) ListSessions() ([]tmuxcm.Session, error) {
	resp, err := c.Exec(tmuxcm.ListSessions())
	if err != nil {
		return nil, err
	}
	if resp.IsError {
		return nil, fmt.Errorf("tmux list-sessions failed: %s", strings.TrimSpace(resp.Output))
	}
	return tmuxcm.ParseSessionList(resp.Output), nil
}

// EnsureSession makes `name` exist on the server and become this control
// client's current session: create-if-missing (`new-session -d`), then
// `switch-client`, then one Barrier so the mirror lists the session before
// the caller acks. Idempotent, and single-flight per client (ensureMu) so
// two racing ensures for the same missing session cannot both create.
func (c *Client) EnsureSession(name string) error {
	c.ensureMu.Lock()
	defer c.ensureMu.Unlock()

	rows, err := c.ListSessions()
	if err != nil {
		return err
	}
	exists := false
	for _, row := range rows {
		if row.Name == name {
			exists = true
			break
		}
	}
	if !exists {
		resp, err := c.Exec(tmuxcm.NewSessionAt(name, ""))
		if err != nil {
			return err
		}
		// "duplicate session" = an outside actor created it between the
		// listing and the create — exactly the world we wanted.
		if resp.IsError && !strings.Contains(resp.Output, "duplicate session") {
			return fmt.Errorf("tmux refused new-session: %s", strings.TrimSpace(resp.Output))
		}
	}
	if c.sessionName() != name {
		resp, err := c.Exec(tmuxcm.SwitchClient(name))
		if err != nil {
			return err
		}
		if resp.IsError {
			return fmt.Errorf("tmux refused switch-client: %s", strings.TrimSpace(resp.Output))
		}
		// %session-changed will confirm (id included); set the name now so
		// a refresh racing the notification doesn't publish the old current.
		c.mu.Lock()
		c.session = name
		c.sessionID = "" // re-learned from %session-changed / next refresh
		c.mu.Unlock()
	}
	// The ack promise: by the time the ensure acks, the mirror lists this
	// session. One full pass — fresh listings, delivery included.
	return c.Barrier(ensureTimeout)
}

// ListStructure takes a FRESH window+pane listing of ONE session (the same
// two commands the mirror refresh runs per session). "" = the client's
// current session. Structure verbs that need lookups — pane→window mapping,
// window ids, session-wide pane order — translate from this rather than the
// cached snapshot, so a verb issued right after another write sees that
// write's world.
func (c *Client) ListStructure(session string) ([]tmuxcm.Window, []tmuxcm.Pane, error) {
	if session == "" {
		session = c.sessionName()
	}
	winResp, err := c.Exec(tmuxcm.ListWindows(session))
	if err != nil {
		return nil, nil, err
	}
	paneResp, err := c.Exec(tmuxcm.ListPanes(session, false, true))
	if err != nil {
		return nil, nil, err
	}
	if winResp.IsError || paneResp.IsError {
		return nil, nil, fmt.Errorf("tmux listing failed (windows: %q; panes: %q)",
			winResp.Output, paneResp.Output)
	}
	return tmuxcm.ParseWindowList(winResp.Output), tmuxcm.ParsePaneList(paneResp.Output), nil
}

// ListAllPanes takes a FRESH server-wide pane listing (`list-panes -a`) —
// the lookup verbs addressing a pane by its server-global id use, since the
// pane may live in any session on the server.
func (c *Client) ListAllPanes() ([]tmuxcm.Pane, error) {
	resp, err := c.Exec(tmuxcm.ListPanes("", true, false))
	if err != nil {
		return nil, err
	}
	if resp.IsError {
		return nil, fmt.Errorf("tmux list-panes -a failed: %s", strings.TrimSpace(resp.Output))
	}
	return tmuxcm.ParsePaneList(resp.Output), nil
}

// CapturePaneText returns a pane's visible screen (capture-pane -p -J -e:
// SGR colors kept, wrapped lines joined) as terminal-renderable bytes — \n
// separators become \r\n, since a renderer fed bare LFs would staircase.
// Empty screen returns nil. This is the scrollback seed for a pane the
// daemon adopts with an empty event log (acphost tmuxPaneFor). Pane ids are
// server-global, so this works for any session's pane.
func (c *Client) CapturePaneText(id tmuxcm.PaneID) ([]byte, error) {
	resp, err := c.Exec(tmuxcm.CapturePane(id, 0, true))
	if err != nil {
		return nil, err
	}
	if resp.IsError {
		return nil, fmt.Errorf("capture-pane %s: %s", id, resp.Output)
	}
	out := strings.TrimRight(resp.Output, "\n")
	if out == "" {
		return nil, nil
	}
	return []byte(strings.ReplaceAll(out, "\n", "\r\n")), nil
}

// SubscribePane starts delivering a pane's %output to onOutput, in order,
// from a dedicated goroutine — the read loop never blocks on a subscriber,
// so one starved viewer cannot stall every pane on the server. onClosed
// fires exactly once when delivery ends: nil = the pane itself closed,
// non-nil = the control client died under it. One subscriber per pane; the
// caller (acphost) multiplexes its own viewers above this.
//
// Honest scope note: tmux only streams %output for panes of the client's
// CURRENT session. A subscription on another session's pane stays silent
// until an ensure switches the client there — the caller sequences ensure
// before attach, so the product path always subscribes on the streaming
// session.
func (c *Client) SubscribePane(id tmuxcm.PaneID, onOutput func([]byte), onClosed func(error)) (cancel func(), err error) {
	c.mu.Lock()
	if c.dead {
		err := c.deadErr
		c.mu.Unlock()
		return nil, fmt.Errorf("tmux control client for %s is gone: %v", c.target, err)
	}
	if _, ok := c.subs[id]; ok {
		c.mu.Unlock()
		return nil, fmt.Errorf("pane %s already has a subscriber", id)
	}
	if !sessionsHavePane(c.sessions, id) {
		c.mu.Unlock()
		return nil, fmt.Errorf("no pane %s on tmux target %q", id, c.target)
	}
	sub := &paneSub{
		pane:     id,
		onOutput: onOutput,
		onClosed: onClosed,
		ch:       make(chan []byte, paneSubQueue),
		done:     make(chan struct{}),
	}
	c.subs[id] = sub
	c.mu.Unlock()
	go sub.pump()
	return func() { c.unsubscribe(id, sub) }, nil
}

func (c *Client) unsubscribe(id tmuxcm.PaneID, sub *paneSub) {
	c.mu.Lock()
	if c.subs[id] == sub {
		delete(c.subs, id)
	}
	c.mu.Unlock()
	sub.cancelSilent()
}

// WritePane types raw bytes into a pane via send-keys -H (hex mode: \r, \n
// and \x1b all survive). Chunked so a huge paste never builds one enormous
// command line for tmux's parser.
func (c *Client) WritePane(id tmuxcm.PaneID, data []byte) error {
	const writeChunk = 4096
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dead {
		return fmt.Errorf("tmux control client for %s is gone: %v", c.target, c.deadErr)
	}
	for off := 0; off < len(data); off += writeChunk {
		c.cm.SendKeysHex(id, data[off:min(off+writeChunk, len(data))])
	}
	return nil
}

// Close tears this control client down. The tmux server and its panes
// stay — see Host.Close.
func (c *Client) Close() {
	c.teardown(errors.New("tmux control client closed by host"))
}

// ---- goroutines ----

func (c *Client) readLoop() {
	buf := make([]byte, 32*1024)
	for {
		n, err := c.ptmx.Read(buf)
		if n > 0 {
			c.mu.Lock()
			if !c.ready && len(c.preReady) < 2048 {
				// Anything tmux says before the greeting is an error message
				// ("no server running on …", a bad -f path); keep it for the
				// ensure failure report, because after the pty closes it is
				// gone.
				c.preReady = append(c.preReady, buf[:n]...)
			}
			c.cm.Feed(buf[:n])
			c.mu.Unlock()
		}
		if err != nil {
			// EOF/EIO: the tmux client is gone (server killed, %exit, or our
			// own teardown closing the pty).
			c.teardown(errors.New("tmux control stream closed"))
			return
		}
	}
}

// handleNotification runs under c.mu, inside Feed. Cheap work only.
func (c *Client) handleNotification(n tmuxcm.Notification) {
	switch v := n.(type) {
	case tmuxcm.Output:
		if len(v.Data) == 0 {
			return
		}
		if sub := c.subs[v.Pane]; sub != nil {
			sub.enqueue(v.Data, c.logf)
		}
	case tmuxcm.LayoutChange, tmuxcm.WindowAdd, tmuxcm.WindowClose,
		tmuxcm.WindowRenamed, tmuxcm.PaneModeChanged, tmuxcm.WindowPaneChanged,
		tmuxcm.SessionWindowChanged,
		tmuxcm.SessionsChanged, tmuxcm.UnlinkedWindowAdd,
		tmuxcm.UnlinkedWindowClose, tmuxcm.UnlinkedWindowRenamed:
		// The linked family for the client's own session; the %sessions-
		// changed / %unlinked-window-* family for every OTHER session on the
		// server — the mirror lists them all, so all of them re-list.
		// (%window-pane-changed and %session-window-changed additionally
		// keep the active-pane/active-window readings fresh.)
		c.requestRefreshLocked()
	case tmuxcm.SessionChanged:
		// The client's current session moved (ensure's switch-client, or an
		// outside switch). Track BOTH identity halves: refreshes reconcile
		// the name by id, so a rename can never strand the listings.
		c.sessionID = v.Session.String()
		c.session = v.Name
		c.requestRefreshLocked()
	case tmuxcm.SessionRenamed:
		// Rename of any session re-lists (the mirror shows every name); the
		// tracked current name moves only when it was OURS that renamed.
		if !v.HasSession || (c.sessionID != "" && v.Session.String() == c.sessionID) {
			c.session = v.Name
		}
		c.requestRefreshLocked()
	case tmuxcm.Exit:
		// %exit precedes the stream close; the read loop's EOF runs the real
		// teardown.
		c.logf("tmux control client got %%exit (%s)", v.Reason)
	}
}

func (c *Client) requestRefreshLocked() {
	select {
	case c.refreshCh <- struct{}{}:
	default:
	}
}

func (c *Client) refreshLoop() {
	for {
		select {
		case <-c.done:
			return
		case <-c.refreshCh:
			c.refreshStructure()
		case done := <-c.syncCh:
			// A Barrier: run a full pass HERE (fresh listings, delivery
			// included) and only then release the waiter. Serialized with
			// ordinary refreshes by construction — one goroutine.
			c.refreshStructure()
			close(done)
		}
	}
}

// refreshStructure re-lists the WHOLE server — sessions, then each
// session's windows and panes — and publishes the snapshot if it changed. A
// full re-list per change rather than incremental patching on purpose: the
// notification stream tells us THAT the structure moved, and tmux's own
// listings are the truth of WHERE to — patching would maintain a second
// model of tmux just to save a few cheap commands.
func (c *Client) refreshStructure() {
	// Pass 1: the session list.
	sesCh := make(chan tmuxcm.CommandResponse, 1)
	c.mu.Lock()
	if c.dead {
		c.mu.Unlock()
		return
	}
	c.cm.Send(tmuxcm.ListSessions(), func(r tmuxcm.CommandResponse) { sesCh <- r })
	c.mu.Unlock()
	sesResp, ok := c.awaitResponse(sesCh)
	if !ok || sesResp.IsError {
		c.logf("tmux structure refresh failed (sessions ok=%v err=%v)", ok, sesResp.IsError)
		return
	}
	rows := tmuxcm.ParseSessionList(sesResp.Output)

	// Pass 2: per-session listings, all issued in ONE lock section (same
	// connection — tmux executes them in order, so the whole batch reads
	// one consistent-enough world), awaited in order.
	type listing struct {
		win  chan tmuxcm.CommandResponse
		pane chan tmuxcm.CommandResponse
	}
	listings := make([]listing, len(rows))
	c.mu.Lock()
	if c.dead {
		c.mu.Unlock()
		return
	}
	sizing := c.sizing
	for i, row := range rows {
		l := listing{
			win:  make(chan tmuxcm.CommandResponse, 1),
			pane: make(chan tmuxcm.CommandResponse, 1),
		}
		listings[i] = l
		// Target by id ($N): rename-stable, so a rename racing this refresh
		// cannot strand the listing on a ghost name.
		target := row.ID.String()
		c.cm.Send(tmuxcm.ListWindows(target), func(r tmuxcm.CommandResponse) { l.win <- r })
		c.cm.Send(tmuxcm.ListPanes(target, false, true), func(r tmuxcm.CommandResponse) { l.pane <- r })
	}
	c.mu.Unlock()

	sessions := make([]SessionStructure, 0, len(rows))
	for i, row := range rows {
		winResp, ok1 := c.awaitResponse(listings[i].win)
		paneResp, ok2 := c.awaitResponse(listings[i].pane)
		if !ok1 || !ok2 {
			// Transport gone or wedged: abort the whole pass.
			c.logf("tmux structure refresh failed (session %s windows ok=%v; panes ok=%v)",
				row.ID, ok1, ok2)
			return
		}
		if winResp.IsError || paneResp.IsError {
			// The session vanished between the list and its listings; its
			// destruction already queued another refresh (%sessions-changed).
			continue
		}
		sessions = append(sessions, SessionStructure{
			ID:   row.ID.String(),
			Name: row.Name,
			Snap: buildSnapshot(tmuxcm.ParseWindowList(winResp.Output), tmuxcm.ParsePaneList(paneResp.Output)),
		})
	}

	var gone []*paneSub
	c.mu.Lock()
	// Reconcile the current session's identity against the fresh listing:
	// the id is authoritative (rename-proof); a client that predates its
	// first %session-changed matches by name instead.
	if c.sessionID == "" {
		for _, s := range sessions {
			if s.Name == c.session {
				c.sessionID = s.ID
				break
			}
		}
	} else {
		for _, s := range sessions {
			if s.ID == c.sessionID {
				c.session = s.Name
				break
			}
		}
	}
	current := c.session
	// The current-session identity and the sizing block participate in
	// change detection alongside the structure: a bare rename or switch
	// alters nothing structural, and setSizePolicy at an unchanged size
	// moves nothing tmux lists — but their ack revs promise the mirror
	// shows them.
	raw, err := json.Marshal(struct {
		Session  string
		Sizing   Sizing
		Sessions []SessionStructure
	}{current, sizing, sessions})
	if err != nil {
		c.mu.Unlock()
		return
	}
	changed := !bytes.Equal(raw, c.snapJSON)
	if changed {
		c.sessions = sessions
		c.snapJSON = raw
		live := make(map[tmuxcm.PaneID]bool)
		for _, s := range sessions {
			for _, id := range s.Snap.AllPanes() {
				live[id] = true
			}
		}
		for id, sub := range c.subs {
			if !live[id] {
				delete(c.subs, id)
				gone = append(gone, sub)
			}
		}
	}
	c.mu.Unlock()

	for _, sub := range gone {
		sub.finish(nil) // nil: the pane itself closed
	}
	if changed && c.onStructure != nil {
		c.onStructure(c.target, current, sessions)
	}
	// Latched AFTER the delivery above — this ordering is what lets
	// EnsureLocal promise "the mirror is written before ensure returns".
	c.firstOnce.Do(func() { close(c.firstSnap) })
}

// awaitResponse waits for one command's reply. teardown releases pending
// replies with an IsError "connection reset" (via cm.Reset), so a dying
// client resolves this promptly; the timeout is a backstop for a wedged
// tmux.
func (c *Client) awaitResponse(ch <-chan tmuxcm.CommandResponse) (tmuxcm.CommandResponse, bool) {
	select {
	case r := <-ch:
		return r, true
	case <-c.done:
		return tmuxcm.CommandResponse{}, false
	case <-time.After(10 * time.Second):
		return tmuxcm.CommandResponse{}, false
	}
}

func buildSnapshot(windows []tmuxcm.Window, panes []tmuxcm.Pane) tmuxcm.StructureSnapshot {
	byWindow := make(map[tmuxcm.WindowID][]tmuxcm.PaneID)
	detailsByWindow := make(map[tmuxcm.WindowID][]tmuxcm.SnapshotPane)
	for _, p := range panes {
		if !p.HasWindowID {
			continue
		}
		byWindow[p.WindowID] = append(byWindow[p.WindowID], p.ID)
		detailsByWindow[p.WindowID] = append(detailsByWindow[p.WindowID], tmuxcm.SnapshotPane{
			ID: p.ID, Title: p.Title,
			Width: p.Width, Height: p.Height, X: p.X, Y: p.Y,
			Active: p.IsActive, Zoomed: p.IsZoomed,
		})
	}
	var snap tmuxcm.StructureSnapshot
	for _, w := range windows {
		snap.Windows = append(snap.Windows, tmuxcm.SnapshotWindow{
			Index: w.Index, Name: w.Name, Layout: w.Layout, Active: w.IsActive,
			Panes: byWindow[w.ID], Details: detailsByWindow[w.ID],
		})
	}
	return snap
}

func sessionsHavePane(sessions []SessionStructure, id tmuxcm.PaneID) bool {
	for _, s := range sessions {
		for _, w := range s.Snap.Windows {
			for _, p := range w.Panes {
				if p == id {
					return true
				}
			}
		}
	}
	return false
}

// teardown ends the client exactly once: pending replies released, pane
// subscriptions failed, the process signalled. Idempotent — the read loop,
// the waiter goroutine and Close all race into it.
func (c *Client) teardown(cause error) {
	c.mu.Lock()
	if c.dead {
		c.mu.Unlock()
		return
	}
	c.dead = true
	if cause == nil {
		cause = errors.New("tmux control client closed")
	}
	if !c.ready && len(c.preReady) > 0 {
		cause = fmt.Errorf("%v; tmux said: %s", cause, strings.TrimSpace(string(c.preReady)))
	}
	c.deadErr = cause
	subs := make([]*paneSub, 0, len(c.subs))
	for _, s := range c.subs {
		subs = append(subs, s)
	}
	c.subs = make(map[tmuxcm.PaneID]*paneSub)
	c.cm.Reset() // releases pending command replies ("connection reset")
	close(c.done)
	ptmx := c.ptmx
	proc := c.proc
	c.mu.Unlock()

	_ = ptmx.Close()
	if proc != nil && proc.Process != nil {
		_ = proc.Process.Signal(syscall.SIGTERM)
	}
	failure := fmt.Errorf("tmux control client for %s: %w", c.target, cause)
	for _, s := range subs {
		s.finish(failure)
	}
	// Release any ensure still waiting; it re-checks dead and reports.
	c.firstOnce.Do(func() { close(c.firstSnap) })
}

// ---- pane subscriptions ----

// paneSubQueue bounds one pane's undelivered output, as a memory backstop
// only. tmux has no per-pane flow control, so a subscriber slower than the
// pane fills this up; overflow drops chunks (logged). Credit-driven read
// pausing and the capture-pane repair belong to a later step (design doc
// §顺序 5).
const paneSubQueue = 4096

// paneSub carries one pane's %output to one subscriber through a dedicated
// pump goroutine, preserving order while keeping the client's read loop
// unblockable.
type paneSub struct {
	pane     tmuxcm.PaneID
	onOutput func([]byte)
	onClosed func(error)
	ch       chan []byte
	done     chan struct{}
	once     sync.Once
	reason   error
	silent   atomic.Bool
}

// enqueue runs under the client's mu (from Feed): non-blocking by
// construction.
func (s *paneSub) enqueue(data []byte, logf func(string, ...any)) {
	select {
	case s.ch <- data:
	default:
		logf("tmux pane %s: output queue overflow, dropping a chunk (capture-pane repair is a later step)", s.pane)
	}
}

// finish ends delivery: what is already queued still drains, then onClosed
// runs exactly once. reason nil = the pane itself closed.
func (s *paneSub) finish(reason error) {
	s.once.Do(func() {
		s.reason = reason
		close(s.done)
	})
}

// cancelSilent ends delivery without the onClosed callback — the caller is
// discarding the subscription and must not be told a pane "closed".
func (s *paneSub) cancelSilent() {
	s.silent.Store(true)
	s.finish(nil)
}

func (s *paneSub) pump() {
	for {
		select {
		case b := <-s.ch:
			s.onOutput(b)
		case <-s.done:
			// Drain what was enqueued before the close — the subscriber gets
			// every byte the pane produced, then the verdict.
			for {
				select {
				case b := <-s.ch:
					s.onOutput(b)
				default:
					if !s.silent.Load() && s.onClosed != nil {
						s.onClosed(s.reason)
					}
					return
				}
			}
		}
	}
}
