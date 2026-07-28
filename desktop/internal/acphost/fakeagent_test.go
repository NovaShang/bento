package acphost

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// A scripted ACP agent, run as a child of the test binary (the os/exec
// helper-process idiom: no external dependency, no toolchain at test time).
//
// /bin/cat is enough to test id translation and fan-out because it echoes,
// but it never ACTS: it can't answer initialize, can't mint a session id,
// and can't stream a replay of its own accord. The paths S0 is actually
// about — a fresh process resuming a conversation, and the daemon deciding
// whether that replay belongs in the log or on anyone's screen — need an
// agent with behavior.
func TestFakeAgentHelperProcess(t *testing.T) {
	if os.Getenv("ACPHOST_FAKE_AGENT") != "1" {
		t.Skip("helper process; runs only as a child")
	}
	runFakeAgent()
	os.Exit(0) // never fall through to the framework's own output
}

// fakeAgentCommand is the spawn Control that starts the helper.
func fakeAgentCommand(sessionID string, replayCount int) Control {
	return Control{
		Op:        "spawn",
		Cmd:       os.Args[0],
		Args:      []string{"-test.run=TestFakeAgentHelperProcess"},
		SessionID: sessionID,
		Env: map[string]string{
			"ACPHOST_FAKE_AGENT": "1",
			"FAKE_AGENT_REPLAY":  fmt.Sprint(replayCount),
			"FAKE_AGENT_SESSION": fakeSessionID,
		},
	}
}

const fakeSessionID = "fake-sess-1"

// runFakeAgent speaks just enough ACP to exercise the daemon: initialize,
// session/new, a prompt that streams updates, and a load that replays the
// conversation the way a real agent does (notifications first, response as
// the ordering boundary).
func runFakeAgent() {
	sessionID := os.Getenv("FAKE_AGENT_SESSION")
	if sessionID == "" {
		sessionID = fakeSessionID
	}
	replay := 0
	fmt.Sscanf(os.Getenv("FAKE_AGENT_REPLAY"), "%d", &replay)

	out := bufio.NewWriter(os.Stdout)
	emit := func(v any) {
		b, _ := json.Marshal(v)
		out.Write(append(b, '\n'))
		out.Flush()
	}
	update := func(text string) {
		emit(map[string]any{
			"jsonrpc": "2.0",
			"method":  "session/update",
			"params": map[string]any{
				"sessionId": sessionID,
				"update": map[string]any{
					"sessionUpdate": "agent_message_chunk",
					"content":       map[string]any{"type": "text", "text": text},
				},
			},
		})
	}
	result := func(id json.RawMessage, res any) {
		emit(map[string]any{"jsonrpc": "2.0", "id": id, "result": res})
	}

	in := bufio.NewReaderSize(os.Stdin, 1<<20)
	for {
		line, err := in.ReadBytes('\n')
		if len(line) > 1 {
			var req struct {
				ID     json.RawMessage `json:"id"`
				Method string          `json:"method"`
			}
			if json.Unmarshal(line, &req) == nil && req.ID != nil {
				switch req.Method {
				case "initialize":
					result(req.ID, map[string]any{
						"protocolVersion":   1,
						"agentCapabilities": map[string]any{"loadSession": true},
					})
				case "session/new":
					result(req.ID, map[string]any{"sessionId": sessionID})
				case "session/prompt":
					for i := 1; i <= replay; i++ {
						update(fmt.Sprintf("turn chunk %d", i))
					}
					result(req.ID, map[string]any{"stopReason": "end_turn"})
				case "session/load":
					// A real agent re-streams the whole conversation, then
					// answers. Same shape here, same ordering.
					for i := 1; i <= replay; i++ {
						update(fmt.Sprintf("replayed chunk %d", i))
					}
					result(req.ID, map[string]any{"modes": map[string]any{"currentModeId": "code"}})
				default:
					result(req.ID, map[string]any{})
				}
			}
		}
		if err != nil {
			return
		}
	}
}

// countingClient reads units until it has seen `want` stdio lines or the
// stream goes quiet, returning the lines.
func drainStdio(t *testing.T, p *plainClient, want int) []string {
	t.Helper()
	var lines []string
	for len(lines) < want {
		lines = append(lines, p.nextStdioLine(t, 5*time.Second))
	}
	return lines
}

// waitFor polls a condition until it holds or the deadline passes.
func waitFor(t *testing.T, timeout time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// A respawned agent holds no conversation until something loads it, and that
// something used to be whichever client attached first — turning the agent's
// private need into a full re-stream of history the client had already been
// given from the log. The daemon spawned the process, so the daemon restores
// it, before anyone attaches and without asking anyone.
func TestDaemonRestoresARespawnedAgentItself(t *testing.T) {
	home := t.TempDir()
	first, _, _ := newServerIn(t, home, true)

	a := newPlainClient(first)
	a.control(fakeAgentCommand("", 3))
	if ctrl := a.nextControl(t, 5*time.Second); ctrl.Op != "attached" {
		t.Fatalf("spawn failed: %+v", ctrl)
	}
	a.stdio(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}`)
	_ = a.nextStdioLine(t, 5*time.Second)
	a.stdio(`{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}`)
	_ = a.nextStdioLine(t, 5*time.Second)
	a.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":%q}}`, fakeSessionID))
	_ = drainStdio(t, a, 4)

	// ---- the daemon restarts; the process is gone with it ----
	second, _, _ := newServerIn(t, home, true)
	b := newPlainClient(second)
	spawn := fakeAgentCommand(fakeSessionID, 3)
	spawn.Catchup = true // cold: b holds nothing
	b.control(spawn)
	ack := b.nextControl(t, 5*time.Second)
	if !ack.Replay || ack.HeadSeq != 3 {
		t.Fatalf("expected the log to serve this client, got %+v", ack)
	}

	inst := second.instance(ack.AgentID)
	if inst == nil {
		t.Fatal("no instance for the respawned agent")
	}
	// Nobody has sent the agent anything — the daemon did this on its own.
	waitFor(t, 10*time.Second, "the daemon to restore the agent", func() bool {
		inst.mu.Lock()
		defer inst.mu.Unlock()
		return inst.initialized && inst.cachedSessionResult != nil
	})

	// b receives its history from the LOG, and nothing from the restore.
	for i := 1; i <= 3; i++ {
		if line := b.nextStdioLine(t, 5*time.Second); !strings.Contains(line, fmt.Sprintf("turn chunk %d", i)) {
			t.Fatalf("expected the logged turn, got %q", line)
		}
	}
	select {
	case u := <-b.out.units:
		t.Fatalf("the restore leaked to a client: %q", u)
	case <-time.After(400 * time.Millisecond):
	}

	// And b's own handshake is answered from the cache the restore filled —
	// the agent is never asked to initialize twice or replay again.
	b.stdio(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}`)
	if line := b.nextStdioLine(t, 5*time.Second); !strings.Contains(line, `"protocolVersion":1`) {
		t.Fatalf("cached initialize failed: %q", line)
	}
	b.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","id":2,"method":"session/load","params":{"sessionId":%q}}`, fakeSessionID))
	resp := b.nextStdioLine(t, 5*time.Second)
	if !strings.Contains(resp, `"id":2`) || !strings.Contains(resp, `"currentModeId":"code"`) {
		t.Fatalf("expected the cached load response, got %q", resp)
	}
	select {
	case u := <-b.out.units:
		t.Fatalf("a second replay reached the client: %q", u)
	case <-time.After(400 * time.Millisecond):
	}
}

// The whole S0 claim, end to end, against an agent that behaves like one:
// a daemon restart becomes a DELTA reattach — the client is served the tail
// it missed from disk, and the fresh agent's own session/load replay (which
// the agent needs, to restore its context) reaches neither the log nor the
// screen a second time.
func TestDaemonRestartServesDeltaAndSuppressesAgentReplay(t *testing.T) {
	home := t.TempDir()
	first, _, _ := newServerIn(t, home, true)

	a := newPlainClient(first)
	a.control(fakeAgentCommand("", 3))
	if ctrl := a.nextControl(t, 5*time.Second); ctrl.Op != "attached" {
		t.Fatalf("spawn failed: %+v", ctrl)
	}
	a.stdio(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}`)
	if line := a.nextStdioLine(t, 5*time.Second); !strings.Contains(line, `"protocolVersion":1`) {
		t.Fatalf("initialize failed: %q", line)
	}
	a.stdio(`{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}`)
	if line := a.nextStdioLine(t, 5*time.Second); !strings.Contains(line, fakeSessionID) {
		t.Fatalf("session/new failed: %q", line)
	}

	// One turn: three updates, logged as seq 1..3.
	a.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":%q}}`, fakeSessionID))
	got := drainStdio(t, a, 4) // 3 updates + the prompt response
	for i, want := range []string{`"_seq":1`, `"_seq":2`, `"_seq":3`, `"stopReason":"end_turn"`} {
		if !strings.Contains(got[i], want) {
			t.Fatalf("turn output %d = %q, want %s", i, got[i], want)
		}
	}

	// ---- the daemon restarts; the agent process is gone with it ----
	second, _, _ := newServerIn(t, home, true)
	b := newPlainClient(second)
	spawn := fakeAgentCommand(fakeSessionID, 3)
	spawn.HaveSeq = 1 // b already applied seq 1 before the restart
	spawn.Catchup = true
	b.control(spawn)

	ack := b.nextControl(t, 5*time.Second)
	if !ack.Replay || ack.HeadSeq != 3 || ack.StartSeq != 1 {
		t.Fatalf("expected a delta replay from the durable log, got %+v", ack)
	}
	delta := drainStdio(t, b, 2)
	for i, want := range []string{`"_seq":2`, `"_seq":3`} {
		if !strings.Contains(delta[i], want) {
			t.Fatalf("delta %d = %q, want %s", i, delta[i], want)
		}
	}

	// The fresh agent still needs its own context back: initialize + load.
	// The load's replay is the agent restoring itself, not new transcript —
	// it must not reach this client (which just caught up) or the log.
	b.stdio(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}`)
	_ = b.nextStdioLine(t, 5*time.Second)
	b.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","id":2,"method":"session/load","params":{"sessionId":%q}}`, fakeSessionID))
	resp := b.nextStdioLine(t, 5*time.Second)
	if !strings.Contains(resp, `"id":2`) || !strings.Contains(resp, `"currentModeId":"code"`) {
		t.Fatalf("expected the load response first, got %q", resp)
	}
	select {
	case u := <-b.out.units:
		t.Fatalf("the agent's restore replay leaked to the client: %q", u)
	case <-time.After(400 * time.Millisecond):
	}

	// And the log still holds exactly the original three updates: a third
	// client attaching cold sees 3, not 6.
	c := newPlainClient(second)
	c.control(Control{Op: "attach", AgentID: ack.AgentID, Catchup: true, HaveSeq: 0})
	cold := c.nextControl(t, 5*time.Second)
	if !cold.Replay || cold.HeadSeq != 3 {
		t.Fatalf("the restore replay was written into the log: %+v", cold)
	}
	lines := drainStdio(t, c, 3)
	for i, want := range []string{"turn chunk 1", "turn chunk 2", "turn chunk 3"} {
		if !strings.Contains(lines[i], want) {
			t.Fatalf("cold replay %d = %q, want the ORIGINAL turn text %q", i, lines[i], want)
		}
	}
}
