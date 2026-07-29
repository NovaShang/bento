package acphost

import (
	"encoding/json"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// The scripted agent proves the daemon's logic; this proves the shape of the
// conversation is real. A live ACP agent goes through the new spawn path
// (which now names the conversation) and answers initialize + session/new,
// and the daemon must end up with that conversation claimed, its durable log
// bound, and a second spawn for it adopting the same process.
//
// No prompt: the handshake is what changed, and a turn would spend the
// user's tokens. Skipped when the agent isn't installed.
func TestRealAgentSpawnBindsConversation(t *testing.T) {
	bin, err := exec.LookPath("claude-agent-acp")
	if err != nil {
		t.Skip("claude-agent-acp not installed")
	}

	server, _, _ := newServer(t, true)
	cwd := t.TempDir() // a throwaway project path, not the user's repo
	a := newPlainClient(server)
	a.control(Control{Op: "spawn", Cmd: bin, Cwd: cwd})
	ack := a.nextControl(t, 20*time.Second)
	if ack.Op != "attached" || !ack.Running {
		t.Fatalf("spawn failed: %+v", ack)
	}

	a.stdio(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":` +
		`{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}}}}`)
	init := a.nextStdioLine(t, 20*time.Second)
	if !strings.Contains(init, `"protocolVersion"`) {
		t.Fatalf("real agent initialize failed: %q", init)
	}

	a.stdio(`{"jsonrpc":"2.0","id":2,"method":"session/new","params":` +
		`{"cwd":"` + cwd + `","mcpServers":[]}}`)
	newResp := a.nextStdioLine(t, 30*time.Second)
	var parsed struct {
		Result struct {
			SessionID string `json:"sessionId"`
		} `json:"result"`
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal([]byte(newResp), &parsed) != nil {
		t.Fatalf("unparseable session/new response: %q", newResp)
	}
	if parsed.Error != nil {
		// Not signed in, no credit, etc. — the agent's business, not the
		// daemon's. Everything up to here still exercised the new path.
		t.Skipf("agent declined session/new (%s); handshake path verified", parsed.Error)
	}
	if parsed.Result.SessionID == "" {
		t.Fatalf("no session id in %q", newResp)
	}
	sessionID := parsed.Result.SessionID

	// The daemon learned the conversation from the response and claimed it.
	inst := server.instance(ack.AgentID)
	inst.mu.Lock()
	bound, claimed := inst.updates.dir, inst.acpSessionID
	inst.mu.Unlock()
	if claimed != sessionID {
		t.Fatalf("conversation not recorded: %q vs %q", claimed, sessionID)
	}
	if bound == "" {
		t.Fatal("a real conversation got no durable log")
	}
	if live := server.liveConversation(sessionID); live != inst {
		t.Fatalf("conversation index missed the live process")
	}

	// A second device opening the same pane adopts it instead of starting a
	// rival agent on the same conversation.
	b := newPlainClient(server)
	b.control(Control{Op: "spawn", Cmd: bin, Cwd: cwd, SessionID: sessionID, Catchup: true})
	adopt := b.nextControl(t, 20*time.Second)
	if adopt.AgentID != ack.AgentID {
		t.Fatalf("second spawn started a rival agent: %s vs %s", adopt.AgentID, ack.AgentID)
	}
	if n := len(server.listInstances()); n != 1 {
		t.Fatalf("expected one process for one conversation, got %d", n)
	}
}
