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
	"github.com/novashang/bento/desktop/internal/tmuxcm"
)

// A control client's declared size. tmux derives window sizes from its
// clients (window-size latest by default), and a pty nobody sized would
// clamp every window to its 0×0; this default holds until the `resize` op
// lands (reserved in acphost/proto.go for a later step).
const (
	defaultCols = 200
	defaultRows = 50
)

// Client is one target's live control-mode connection: the `tmux -CC`
// process on its pty, the goroutines that pump it, and the current
// structure snapshot.
type Client struct {
	target      string
	logf        func(string, ...any)
	onStructure func(target, session string, snap tmuxcm.StructureSnapshot)

	// mu guards cm (tmuxcm is deliberately synchronous: every Feed and every
	// Send happens under this lock), the snapshot, the session name and the
	// subscription table. Callbacks out of cm fire under mu and therefore do
	// only cheap state updates and channel signals; anything that can block —
	// subscriber delivery, the structure mirror — runs on its own goroutine.
	mu       sync.Mutex
	cm       *tmuxcm.ControlMode
	proc     *exec.Cmd
	ptmx     *os.File
	session  string
	dead     bool
	deadErr  error
	ready    bool
	preReady []byte // raw output before the greeting, kept for error reports
	snapshot tmuxcm.StructureSnapshot
	snapJSON []byte
	subs     map[tmuxcm.PaneID]*paneSub

	// refreshCh coalesces structure-refresh requests (buffered 1: a burst of
	// %layout-change during a refresh collapses into one follow-up).
	refreshCh chan struct{}
	// firstSnap latches once the first snapshot has been delivered through
	// OnStructure — the gate EnsureLocal waits behind. Also closed by
	// teardown so a client that dies before ready releases its waiters.
	firstSnap chan struct{}
	firstOnce sync.Once
	done      chan struct{}
}

// launchLocal execs `tmux -CC` for a local target. Two facts shape the how:
//
//   - The command line is tmuxcm.LaunchCommand's — the same `new-session -A`
//     ensure line the frozen product types into a shell — with the resolved
//     binary and the private -L socket spliced in front. Reusing it keeps
//     the create-or-attach semantics in ONE place.
//   - tmux -CC insists on a tty (tcgetattr on stdin) even though control
//     mode is line-oriented; over plain pipes it dies with "tcgetattr
//     failed" before attaching (verified live, and the reason tmuxcm's live
//     tests attach through /usr/bin/script). So the client lives on a pty.
func launchLocal(cfg Config, session string) (*Client, error) {
	bin, err := resolveTmux(cfg.TmuxPath)
	if err != nil {
		return nil, err
	}
	launch := strings.TrimPrefix(
		strings.TrimSuffix(tmuxcm.LaunchCommand(session, "", "", ""), "\n"), "tmux")
	shellLine := "exec " + tmuxcm.ShellQuoteArg(bin) +
		" -L " + tmuxcm.ShellQuoteArg(cfg.SocketName)
	if cfg.ConfigFile != "" {
		shellLine += " -f " + tmuxcm.ShellQuoteArg(cfg.ConfigFile)
	}
	shellLine += launch

	cmd := exec.Command("/bin/sh", "-c", shellLine)
	c := &Client{
		target:      LocalTarget,
		logf:        cfg.Logf,
		onStructure: cfg.OnStructure,
		session:     session,
		subs:        make(map[tmuxcm.PaneID]*paneSub),
		refreshCh:   make(chan struct{}, 1),
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
			// the first structure snapshot.
			c.cm.SendFireAndForget(tmuxcm.RefreshClient(defaultCols, defaultRows))
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

func (c *Client) sessionName() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.session
}

// Structure returns the current snapshot. Treat it as read-only: refreshes
// replace it wholesale, never mutate it.
func (c *Client) Structure() tmuxcm.StructureSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.snapshot
}

// SubscribePane starts delivering a pane's %output to onOutput, in order,
// from a dedicated goroutine — the read loop never blocks on a subscriber,
// so one starved viewer cannot stall every pane on the server. onClosed
// fires exactly once when delivery ends: nil = the pane itself closed,
// non-nil = the control client died under it. One subscriber per pane; the
// caller (acphost) multiplexes its own viewers above this.
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
	if !snapshotHasPane(c.snapshot, id) {
		session := c.session
		c.mu.Unlock()
		return nil, fmt.Errorf("no pane %s in tmux session %q", id, session)
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
		tmuxcm.WindowRenamed, tmuxcm.PaneModeChanged:
		c.requestRefreshLocked()
	case tmuxcm.SessionChanged:
		// Structure listings target the session BY NAME, so the name must
		// track renames/switches or every later refresh lists a ghost.
		c.session = v.Name
		c.requestRefreshLocked()
	case tmuxcm.SessionRenamed:
		c.session = v.Name
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
		}
		c.refreshStructure()
	}
}

// refreshStructure re-lists windows and panes and publishes the snapshot if
// it changed. A full re-list per change rather than incremental patching on
// purpose: the notification stream tells us THAT the structure moved, and
// tmux's own listings are the truth of WHERE to — patching would maintain a
// second model of tmux just to save two cheap commands.
func (c *Client) refreshStructure() {
	winCh := make(chan tmuxcm.CommandResponse, 1)
	paneCh := make(chan tmuxcm.CommandResponse, 1)
	c.mu.Lock()
	if c.dead {
		c.mu.Unlock()
		return
	}
	session := c.session
	c.cm.Send(tmuxcm.ListWindows(session), func(r tmuxcm.CommandResponse) { winCh <- r })
	c.cm.Send(tmuxcm.ListPanes(session, false, true), func(r tmuxcm.CommandResponse) { paneCh <- r })
	c.mu.Unlock()

	winResp, ok1 := c.awaitResponse(winCh)
	paneResp, ok2 := c.awaitResponse(paneCh)
	if !ok1 || !ok2 || winResp.IsError || paneResp.IsError {
		c.logf("tmux structure refresh failed (windows ok=%v err=%v; panes ok=%v err=%v)",
			ok1, winResp.IsError, ok2, paneResp.IsError)
		return
	}
	snap := buildSnapshot(tmuxcm.ParseWindowList(winResp.Output), tmuxcm.ParsePaneList(paneResp.Output))
	raw, err := json.Marshal(snap)
	if err != nil {
		return
	}

	var gone []*paneSub
	c.mu.Lock()
	changed := !bytes.Equal(raw, c.snapJSON)
	if changed {
		c.snapshot = snap
		c.snapJSON = raw
		live := make(map[tmuxcm.PaneID]bool)
		for _, id := range snap.AllPanes() {
			live[id] = true
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
		c.onStructure(c.target, session, snap)
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
	for _, p := range panes {
		if !p.HasWindowID {
			continue
		}
		byWindow[p.WindowID] = append(byWindow[p.WindowID], p.ID)
	}
	var snap tmuxcm.StructureSnapshot
	for _, w := range windows {
		snap.Windows = append(snap.Windows, tmuxcm.SnapshotWindow{
			Index: w.Index, Name: w.Name, Layout: w.Layout, Panes: byWindow[w.ID],
		})
	}
	return snap
}

func snapshotHasPane(snap tmuxcm.StructureSnapshot, id tmuxcm.PaneID) bool {
	for _, w := range snap.Windows {
		for _, p := range w.Panes {
			if p == id {
				return true
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
