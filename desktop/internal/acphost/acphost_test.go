package acphost

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/novashang/bento/desktop/internal/hostidentity"
	"golang.org/x/crypto/ssh"
)

// collectWriter gathers daemon→client bytes and hands parsed units to tests.
type collectWriter struct {
	mu    sync.Mutex
	buf   unitBuffer
	units chan []byte
}

func newCollectWriter() *collectWriter {
	return &collectWriter{units: make(chan []byte, 4096)}
}

func (w *collectWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	units, err := w.buf.append(p)
	w.mu.Unlock()
	if err != nil {
		return 0, err
	}
	for _, u := range units {
		w.units <- u
	}
	return len(p), nil
}

func (w *collectWriter) next(t *testing.T, timeout time.Duration) []byte {
	t.Helper()
	select {
	case u := <-w.units:
		return u
	case <-time.After(timeout):
		t.Fatalf("timed out waiting for unit")
		return nil
	}
}

// clientSim is the device side of the handshake + sealed transport
// (relay/encrypted path).
type clientSim struct {
	deviceID string
	identity ed25519.PrivateKey
	eph      *ephemeral
	sealOut  *boxer // c2s
	sealIn   *boxer // s2c
}

func (c *clientSim) hello(t *testing.T, daemonID string) []byte {
	t.Helper()
	var err error
	c.eph, err = newEphemeral()
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Now().Unix()
	ephB64 := c.eph.publicB64()
	sig := ed25519.Sign(c.identity, helloSigMessage(daemonID, c.deviceID, ts, ephB64))
	body, _ := json.Marshal(Hello{
		V: ProtocolV1, DeviceID: c.deviceID, TS: ts, EphPub: ephB64,
		Sig: base64.StdEncoding.EncodeToString(sig),
	})
	return prefixUnit(body)
}

func (c *clientSim) completeHandshake(t *testing.T, daemonID string, welcomeUnit []byte, hostPub ed25519.PublicKey, ts int64) {
	t.Helper()
	var welcome Welcome
	if err := json.Unmarshal(welcomeUnit, &welcome); err != nil {
		t.Fatalf("bad welcome: %v", err)
	}
	if welcome.Error != "" {
		t.Fatalf("handshake rejected: %s", welcome.Error)
	}
	msg := welcomeSigMessage(daemonID, c.deviceID, ts, c.eph.publicB64(), welcome.EphPub)
	if err := verifyEd25519(hostPub, msg, welcome.Sig); err != nil {
		t.Fatalf("host signature invalid: %v", err)
	}
	shared, err := c.eph.shared(welcome.EphPub)
	if err != nil {
		t.Fatal(err)
	}
	c2s, s2c, err := deriveKeys(shared, daemonID, c.deviceID)
	if err != nil {
		t.Fatal(err)
	}
	c.sealOut, _ = newBoxer(c2s)
	c.sealIn, _ = newBoxer(s2c)
}

func (c *clientSim) sealControl(t *testing.T, ctrl Control) []byte {
	t.Helper()
	plain := append([]byte{unitTypeControl}, marshalControl(ctrl)...)
	return prefixUnit(c.sealOut.seal(plain))
}

func (c *clientSim) sealStdio(data []byte) []byte {
	plain := append([]byte{unitTypeStdio}, data...)
	return prefixUnit(c.sealOut.seal(plain))
}

func (c *clientSim) open(t *testing.T, unit []byte) (byte, []byte) {
	t.Helper()
	plain, err := c.sealIn.open(unit)
	if err != nil {
		t.Fatalf("open sealed unit: %v", err)
	}
	return plain[0], plain[1:]
}

// testRig wires a Server plus an encrypted session for handshake tests.
type testRig struct {
	server *Server
	sess   *session
	out    *collectWriter
	client *clientSim
	hostPK ed25519.PublicKey
}

func newServer(t *testing.T, registerDevice bool) (*Server, ed25519.PrivateKey, ed25519.PublicKey) {
	t.Helper()
	dir := t.TempDir()

	hostSigner, err := hostidentity.LoadOrCreateHostKey(filepath.Join(dir, "hostkey"))
	if err != nil {
		t.Fatal(err)
	}
	hostWrap := hostidentity.HostSigner{Signer: hostSigner}
	hostPK := ed25519.PublicKey(hostWrap.RawPublicKey())

	devPub, devPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	authPath := filepath.Join(dir, "authorized_keys")
	if registerDevice {
		sshPub, err := ssh.NewPublicKey(devPub)
		if err != nil {
			t.Fatal(err)
		}
		line := fmt.Sprintf("%s bento-device:dev-test:unit-test:%d\n",
			string(bytes.TrimRight(ssh.MarshalAuthorizedKey(sshPub), "\n")), time.Now().Unix())
		if err := os.WriteFile(authPath, []byte(line), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	keys, err := hostidentity.OpenAuthorizedKeys(authPath)
	if err != nil {
		t.Fatal(err)
	}

	server := New(Options{
		Log:        slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn})),
		Keys:       keys,
		HostSigner: hostWrap,
		DaemonID:   "daemon-test",
	})
	return server, devPriv, hostPK
}

func newTestRig(t *testing.T, registerDevice bool) *testRig {
	t.Helper()
	server, devPriv, hostPK := newServer(t, registerDevice)
	out := newCollectWriter()
	sess := server.openWithWriter(7, out)
	return &testRig{
		server: server,
		sess:   sess,
		out:    out,
		client: &clientSim{deviceID: "dev-test", identity: devPriv},
		hostPK: hostPK,
	}
}

func (r *testRig) handshake(t *testing.T) {
	t.Helper()
	hello := r.client.hello(t, "daemon-test")
	var h Hello
	_ = json.Unmarshal(hello[4:], &h)
	if _, err := r.sess.Write(hello); err != nil {
		t.Fatal(err)
	}
	welcome := r.out.next(t, 2*time.Second)
	r.client.completeHandshake(t, "daemon-test", welcome, r.hostPK, h.TS)
}

// plainClient drives a plaintext (unix-socket-style) session directly.
type plainClient struct {
	sess *session
	out  *collectWriter
}

func newPlainClient(server *Server) *plainClient {
	out := newCollectWriter()
	return &plainClient{sess: server.openPlaintext(out), out: out}
}

func (p *plainClient) control(c Control) {
	body := append([]byte{unitTypeControl}, marshalControl(c)...)
	_, _ = p.sess.Write(prefixUnit(body))
}

func (p *plainClient) stdio(line string) {
	body := append([]byte{unitTypeStdio}, []byte(line+"\n")...)
	_, _ = p.sess.Write(prefixUnit(body))
}

// stdioRaw sends bytes without appending a newline (partial-line cases).
func (p *plainClient) stdioRaw(b []byte) {
	body := append([]byte{unitTypeStdio}, b...)
	_, _ = p.sess.Write(prefixUnit(body))
}

// expectStdioLineNoDetach drains units until `want` arrives, failing the
// test if a `detached` control shows up on the way.
func (p *plainClient) expectStdioLineNoDetach(t *testing.T, want string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		remain := time.Until(deadline)
		if remain <= 0 {
			t.Fatalf("timed out waiting for %q", want)
		}
		typ, payload := p.nextUnit(t, remain)
		if typ == unitTypeControl {
			var c Control
			_ = json.Unmarshal(payload, &c)
			if c.Op == "detached" {
				t.Fatal("unexpected detached control")
			}
			continue
		}
		if strings.TrimRight(string(payload), "\n") == want {
			return
		}
	}
}

// nextUnit returns (type, payload).
func (p *plainClient) nextUnit(t *testing.T, timeout time.Duration) (byte, []byte) {
	t.Helper()
	u := p.out.next(t, timeout)
	if len(u) == 0 {
		t.Fatal("empty unit")
	}
	return u[0], u[1:]
}

func (p *plainClient) nextControl(t *testing.T, timeout time.Duration) Control {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		remain := time.Until(deadline)
		if remain <= 0 {
			t.Fatal("timed out waiting for control")
		}
		typ, payload := p.nextUnit(t, remain)
		if typ != unitTypeControl {
			continue
		}
		var c Control
		_ = json.Unmarshal(payload, &c)
		return c
	}
}

func (p *plainClient) nextStdioLine(t *testing.T, timeout time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		remain := time.Until(deadline)
		if remain <= 0 {
			t.Fatal("timed out waiting for stdio")
		}
		typ, payload := p.nextUnit(t, remain)
		if typ != unitTypeStdio {
			continue
		}
		return strings.TrimRight(string(payload), "\n")
	}
}

// spawnCat spawns /bin/cat (echoes every stdio line back through the
// JSON-RPC proxy) and waits for the attached ack.
func (p *plainClient) spawnCat(t *testing.T) string {
	t.Helper()
	p.control(Control{Op: "spawn", Cmd: "/bin/cat"})
	ctrl := p.nextControl(t, 3*time.Second)
	if ctrl.Op != "attached" || !ctrl.Running {
		t.Fatalf("expected attached running, got %+v", ctrl)
	}
	return ctrl.AgentID
}

// ---- handshake / crypto path (unchanged mechanics) ----

func TestHandshakeEncryptedSpawnAndEcho(t *testing.T) {
	rig := newTestRig(t, true)
	rig.handshake(t)

	_, _ = rig.sess.Write(rig.client.sealControl(t, Control{Op: "spawn", Cmd: "/bin/cat"}))
	typ, payload := rig.client.open(t, rig.out.next(t, 3*time.Second))
	if typ != unitTypeControl {
		t.Fatalf("expected control, got %d", typ)
	}
	var ctrl Control
	_ = json.Unmarshal(payload, &ctrl)
	if ctrl.Op != "attached" || ctrl.AgentID == "" {
		t.Fatalf("expected attached, got %+v", ctrl)
	}

	// A notification passes through verbatim and echoes back.
	note := `{"jsonrpc":"2.0","method":"echo/test","params":{"x":1}}`
	_, _ = rig.sess.Write(rig.client.sealStdio([]byte(note + "\n")))
	deadline := time.Now().Add(3 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatal("echo not received")
		}
		typ, payload = rig.client.open(t, rig.out.next(t, 3*time.Second))
		if typ == unitTypeStdio && strings.TrimSpace(string(payload)) == note {
			return
		}
	}
}

func TestRejectsUnknownDevice(t *testing.T) {
	rig := newTestRig(t, false)
	_, _ = rig.sess.Write(rig.client.hello(t, "daemon-test"))
	var w Welcome
	_ = json.Unmarshal(rig.out.next(t, 2*time.Second), &w)
	if w.Error == "" {
		t.Fatal("expected handshake rejection")
	}
}

func TestRejectsBadSignature(t *testing.T) {
	rig := newTestRig(t, true)
	_, wrongKey, _ := ed25519.GenerateKey(rand.Reader)
	rig.client.identity = wrongKey
	_, _ = rig.sess.Write(rig.client.hello(t, "daemon-test"))
	var w Welcome
	_ = json.Unmarshal(rig.out.next(t, 2*time.Second), &w)
	if w.Error == "" {
		t.Fatal("expected signature rejection")
	}
}

func TestRejectsStaleTimestamp(t *testing.T) {
	rig := newTestRig(t, true)
	eph, _ := newEphemeral()
	ts := time.Now().Add(-10 * time.Minute).Unix()
	ephB64 := eph.publicB64()
	sig := ed25519.Sign(rig.client.identity, helloSigMessage("daemon-test", "dev-test", ts, ephB64))
	body, _ := json.Marshal(Hello{
		V: ProtocolV1, DeviceID: "dev-test", TS: ts, EphPub: ephB64,
		Sig: base64.StdEncoding.EncodeToString(sig),
	})
	_, _ = rig.sess.Write(prefixUnit(body))
	var w Welcome
	_ = json.Unmarshal(rig.out.next(t, 2*time.Second), &w)
	if w.Error == "" {
		t.Fatal("expected stale-timestamp rejection")
	}
}

// ---- persistent-instance semantics (plaintext path for brevity) ----

func TestRequestIDTranslationRoundTrip(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)
	client.spawnCat(t)

	// Client request id 5 → proxy rewrites → cat echoes the request →
	// proxy queues it as an "agent request" with the translated id.
	client.stdio(`{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":1}}`)
	echoed := client.nextStdioLine(t, 3*time.Second)
	var echoedReq rpcShape
	_ = json.Unmarshal([]byte(echoed), &echoedReq)
	if echoedReq.Method != "initialize" || string(echoedReq.ID) == "5" {
		t.Fatalf("expected translated request id, got %s", echoed)
	}

	// Client answers the agent request (verbatim id) → cat echoes the
	// response → proxy maps it back to the ORIGINAL client id 5.
	client.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}`, echoedReq.ID))
	mapped := client.nextStdioLine(t, 3*time.Second)
	var resp rpcShape
	_ = json.Unmarshal([]byte(mapped), &resp)
	if string(resp.ID) != "5" || resp.Result == nil {
		t.Fatalf("expected response mapped to id 5, got %s", mapped)
	}
}

func TestDetachDoesNotKillAgent(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)

	_ = a.sess.Close() // stream gone — agent must keep running

	time.Sleep(100 * time.Millisecond)
	list := server.listInstances()
	if len(list) != 1 || !list[0].Running || list[0].Attached {
		t.Fatalf("expected 1 running detached agent, got %+v", list)
	}

	// New stream attaches and the same process still echoes.
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	ctrl := b.nextControl(t, 2*time.Second)
	if ctrl.Op != "attached" || !ctrl.Running {
		t.Fatalf("expected attached, got %+v", ctrl)
	}
	note := `{"jsonrpc":"2.0","method":"still/alive"}`
	b.stdio(note)
	if got := b.nextStdioLine(t, 3*time.Second); got != note {
		t.Fatalf("echo after reattach mismatch: %q", got)
	}
}

func TestPendingAgentRequestReplayedOnReattach(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)

	// Manufacture a pending agent request: send a client request; cat's
	// echo is parsed as an agent→client request and queued.
	a.stdio(`{"jsonrpc":"2.0","id":1,"method":"session/request_permission","params":{}}`)
	_ = a.nextStdioLine(t, 3*time.Second) // delivered to A once
	_ = a.sess.Close()                    // A leaves with the request unanswered

	list := server.listInstances()
	if len(list) != 1 || !list[0].AwaitingPerm {
		t.Fatalf("expected awaiting_perm after detach, got %+v", list)
	}

	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	if ctrl := b.nextControl(t, 2*time.Second); ctrl.Op != "attached" {
		t.Fatalf("expected attached, got %+v", ctrl)
	}
	replayed := b.nextStdioLine(t, 2*time.Second)
	var req rpcShape
	_ = json.Unmarshal([]byte(replayed), &req)
	if req.Method != "session/request_permission" {
		t.Fatalf("expected replayed permission request, got %q", replayed)
	}
}

// Attachment is multi-subscriber: a second attach must NOT displace the
// first, and agent traffic broadcasts to every attached stream.
func TestMultiAttachCoViews(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)

	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	if ctrl := b.nextControl(t, 2*time.Second); ctrl.Op != "attached" {
		t.Fatalf("expected attached on B, got %+v", ctrl)
	}

	// A notification from A echoes through cat and broadcasts to BOTH; A
	// must never see a detached control.
	note := `{"jsonrpc":"2.0","method":"co/view"}`
	a.stdio(note)
	a.expectStdioLineNoDetach(t, note, 3*time.Second)
	if got := b.nextStdioLine(t, 3*time.Second); got != note {
		t.Fatalf("B missed broadcast: %q", got)
	}

	list := server.listInstances()
	if len(list) != 1 || !list[0].Attached {
		t.Fatalf("expected attached instance, got %+v", list)
	}
}

// A response routes ONLY to the stream that issued the request (with its
// original id restored), and the first answer to a broadcast agent request
// wins — the duplicate never reaches the agent.
func TestResponseRoutesToOriginFirstAnswerWins(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	_ = b.nextControl(t, 2*time.Second)

	// A's request is id-rewritten to agent id 1; cat echoes it back, which
	// the daemon parses as an agent→client REQUEST and broadcasts to both.
	a.stdio(`{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{}}`)
	reqA := a.nextStdioLine(t, 3*time.Second)
	reqB := b.nextStdioLine(t, 3*time.Second)
	if reqA != reqB || !strings.Contains(reqA, `"id":1`) {
		t.Fatalf("broadcast mismatch: A=%q B=%q", reqA, reqB)
	}

	// B answers first → forwarded to the agent (cat echoes it), and the
	// echoed RESPONSE routes to A only, with A's original id restored.
	b.stdio(`{"jsonrpc":"2.0","id":1,"result":{"ok":true}}`)
	resp := a.nextStdioLine(t, 3*time.Second)
	var rs rpcShape
	_ = json.Unmarshal([]byte(resp), &rs)
	if idKey(rs.ID) != "42" || rs.Method != "" {
		t.Fatalf("expected id-42 response on A, got %q", resp)
	}

	// A's late duplicate answer is dropped (never reaches the agent): the
	// next line both sides see is the marker broadcast, not a re-echo.
	a.stdio(`{"jsonrpc":"2.0","id":1,"result":{"late":true}}`)
	marker := `{"jsonrpc":"2.0","method":"after/dup"}`
	a.stdio(marker)
	if got := a.nextStdioLine(t, 3*time.Second); got != marker {
		t.Fatalf("duplicate answer leaked to agent: %q", got)
	}
	if got := b.nextStdioLine(t, 3*time.Second); got != marker {
		t.Fatalf("B out of sync: %q", got)
	}
}

// A finished prompt delivers the JSON-RPC response to its origin and a
// turnDone control to every other attached stream.
func TestTurnDoneBroadcastToObservers(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	_ = b.nextControl(t, 2*time.Second)

	// A prompts (rewritten to agent id 1); cat's echo is broadcast as an
	// agent request; B answers it with a stopReason, which cat echoes back
	// as the prompt RESPONSE.
	a.stdio(`{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{}}`)
	_ = a.nextStdioLine(t, 3*time.Second)
	_ = b.nextStdioLine(t, 3*time.Second)
	b.stdio(`{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}`)

	resp := a.nextStdioLine(t, 3*time.Second)
	if !strings.Contains(resp, `"id":5`) {
		t.Fatalf("expected prompt response on A, got %q", resp)
	}
	ctrl := b.nextControl(t, 3*time.Second)
	if ctrl.Op != "turnDone" || ctrl.Line != "end_turn" {
		t.Fatalf("expected turnDone on B, got %+v", ctrl)
	}
}

// Partial-line reassembly is per attached stream: one client's incomplete
// line must never splice into another client's bytes.
func TestPerStreamLineReassembly(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	_ = b.nextControl(t, 2*time.Second)

	// A sends half a line (no newline); B's complete line goes through
	// intact while A's fragment stays buffered.
	a.stdioRaw([]byte(`{"jsonrpc":"2.0","method":"a/sp`))
	bNote := `{"jsonrpc":"2.0","method":"b/whole"}`
	b.stdio(bNote)
	if got := a.nextStdioLine(t, 3*time.Second); got != bNote {
		t.Fatalf("expected B's line first, got %q", got)
	}

	// A completes its line; it comes through uncorrupted.
	a.stdioRaw([]byte("lit\"}\n"))
	want := `{"jsonrpc":"2.0","method":"a/split"}`
	if got := a.nextStdioLine(t, 3*time.Second); got != want {
		t.Fatalf("split line corrupted: %q", got)
	}
}

func TestKillDeliversExit(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)
	client.spawnCat(t)
	client.control(Control{Op: "kill"})
	deadline := time.Now().Add(5 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatal("no exit control")
		}
		ctrl := client.nextControl(t, 5*time.Second)
		if ctrl.Op == "exit" {
			return
		}
	}
}

func TestCreditWindowGovernsForwarding(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)

	// Emit ~600 KiB of JSON notification lines — more than InitialWindow.
	pad := strings.Repeat("x", 100)
	script := fmt.Sprintf(
		`i=0; while [ $i -lt 5000 ]; do echo "{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":{\"pad\":\"%s\"}}"; i=$((i+1)); done`,
		pad)
	client.control(Control{Op: "spawn", Cmd: "/bin/sh", Args: []string{"-c", script}})
	if ctrl := client.nextControl(t, 3*time.Second); ctrl.Op != "attached" {
		t.Fatalf("expected attached, got %+v", ctrl)
	}

	received := 0
	drain := func(maxWait time.Duration) {
		for {
			select {
			case u := <-client.out.units:
				if len(u) > 0 && u[0] == unitTypeStdio {
					received += len(u) - 1
				}
			case <-time.After(maxWait):
				return
			}
		}
	}
	drain(1500 * time.Millisecond)
	if received == 0 {
		t.Fatal("no output")
	}
	if received > InitialWindow+64*1024 {
		t.Fatalf("window not enforced: %d", received)
	}
	client.control(Control{Op: "credit", Bytes: 4 << 20})
	drain(2 * time.Second)
	if received < 600*1024 {
		t.Fatalf("did not receive full output after credit: %d", received)
	}
}

func TestListDir(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)

	dir := t.TempDir()
	_ = os.Mkdir(filepath.Join(dir, "sub"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "file.txt"), []byte("x"), 0o644)

	client.control(Control{Op: "listdir", Path: dir})
	ctrl := client.nextControl(t, 2*time.Second)
	if ctrl.Op != "dirents" || len(ctrl.Entries) != 2 {
		t.Fatalf("unexpected dirents: %+v", ctrl)
	}
	if !ctrl.Entries[0].Dir || ctrl.Entries[0].Name != "sub" {
		t.Fatalf("dirs should sort first: %+v", ctrl.Entries)
	}
}

func TestUnitBufferReassembly(t *testing.T) {
	var ub unitBuffer
	unit := prefixUnit([]byte("hello"))
	units, err := ub.append(unit[:3])
	if err != nil || len(units) != 0 {
		t.Fatalf("unexpected: %v %d", err, len(units))
	}
	units, err = ub.append(unit[3:])
	if err != nil || len(units) != 1 || string(units[0]) != "hello" {
		t.Fatalf("reassembly failed: %v %q", err, units)
	}
	both := append(prefixUnit([]byte("a")), prefixUnit([]byte("b"))...)
	units, _ = ub.append(both)
	if len(units) != 2 || string(units[0]) != "a" || string(units[1]) != "b" {
		t.Fatalf("multi-unit failed: %q", units)
	}
}

func TestBoxerCounterMismatchFails(t *testing.T) {
	key := make([]byte, 32)
	a, _ := newBoxer(key)
	b, _ := newBoxer(key)
	box1 := a.seal([]byte("one"))
	box2 := a.seal([]byte("two"))
	if _, err := b.open(box2); err == nil {
		t.Fatal("expected out-of-order open to fail")
	}
	c, _ := newBoxer(key)
	if got, err := c.open(box1); err != nil || string(got) != "one" {
		t.Fatalf("in-order open failed: %v %q", err, got)
	}
}

func TestReadFile(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)

	dir := t.TempDir()
	path := filepath.Join(dir, "hello.md")
	_ = os.WriteFile(path, []byte("# Title\nbody"), 0o644)

	client.control(Control{Op: "readfile", Path: path})
	ctrl := client.nextControl(t, 2*time.Second)
	if ctrl.Op != "filedata" || ctrl.Error != "" {
		t.Fatalf("unexpected: %+v", ctrl)
	}
	decoded, _ := base64.StdEncoding.DecodeString(ctrl.Data)
	if string(decoded) != "# Title\nbody" {
		t.Fatalf("content mismatch: %q", decoded)
	}

	client.control(Control{Op: "readfile", Path: filepath.Join(dir, "missing.txt")})
	if ctrl := client.nextControl(t, 2*time.Second); ctrl.Error == "" {
		t.Fatal("expected error for missing file")
	}
}

func TestStateKVRoundTripAndFanout(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	b := newPlainClient(server)

	// Write from A: B (and only B) gets statechanged.
	a.control(Control{Op: "setstate", Key: "workspace", Data: "aGVsbG8="})
	ctrl := b.nextControl(t, 2*time.Second)
	if ctrl.Op != "statechanged" || ctrl.Key != "workspace" {
		t.Fatalf("expected statechanged on peer, got %+v", ctrl)
	}

	// B pulls the value.
	b.control(Control{Op: "getstate", Key: "workspace"})
	ctrl = b.nextControl(t, 2*time.Second)
	if ctrl.Op != "statedata" || ctrl.Data != "aGVsbG8=" {
		t.Fatalf("unexpected statedata: %+v", ctrl)
	}

	// Unknown key reads empty.
	b.control(Control{Op: "getstate", Key: "missing"})
	ctrl = b.nextControl(t, 2*time.Second)
	if ctrl.Op != "statedata" || ctrl.Data != "" {
		t.Fatalf("expected empty statedata: %+v", ctrl)
	}
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
}

func TestStateKVPersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "state.json")

	s1 := New(Options{Log: testLogger(), StateFile: file})
	s1.setState("workspace", "djE=", nil)

	s2 := New(Options{Log: testLogger(), StateFile: file})
	if got := s2.getState("workspace"); got != "djE=" {
		t.Fatalf("state not restored: %q", got)
	}

	// Deleting persists too.
	s2.setState("workspace", "", nil)
	s3 := New(Options{Log: testLogger(), StateFile: file})
	if got := s3.getState("workspace"); got != "" {
		t.Fatalf("delete not persisted: %q", got)
	}
}

// ---- large-payload chunking (MaxUnit must never tear the transport) ----

// A stdio line longer than StdioChunk leaves the daemon as several units,
// each under MaxUnit, and byte-identical after reassembly.
func TestLargeStdioLineChunked(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)

	// Pre-grant credit so the windowed send never blocks the test goroutine.
	client.control(Control{Op: "credit", Bytes: 8 << 20})

	line := append(bytes.Repeat([]byte("x"), 600*1024), '\n')
	client.sess.sendStdio(line)

	var got []byte
	units := 0
	for len(got) < len(line) {
		typ, payload := client.nextUnit(t, 2*time.Second)
		if typ != unitTypeStdio {
			continue
		}
		if len(payload) > StdioChunk {
			t.Fatalf("unit payload %d exceeds StdioChunk", len(payload))
		}
		got = append(got, payload...)
		units++
	}
	if units < 3 {
		t.Fatalf("expected ≥3 chunks for 600KiB, got %d", units)
	}
	if !bytes.Equal(got, line) {
		t.Fatal("reassembled stdio differs from the original line")
	}
}

// readFile splits big files across several filedata messages (more=true on
// all but the last); the concatenated base64 decodes to the file.
func TestReadFileChunked(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)

	content := bytes.Repeat([]byte("0123456789abcdef\n"), 70000) // ~1.2 MiB
	dir := t.TempDir()
	path := filepath.Join(dir, "big.txt")
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatal(err)
	}

	client.control(Control{Op: "readfile", Path: path})
	var b64 string
	messages := 0
	for {
		ctrl := client.nextControl(t, 5*time.Second)
		if ctrl.Op != "filedata" || ctrl.Error != "" {
			t.Fatalf("unexpected control: %+v", ctrl)
		}
		if len(ctrl.Data) > fileDataChunk {
			t.Fatalf("filedata chunk %d exceeds cap", len(ctrl.Data))
		}
		b64 += ctrl.Data
		messages++
		if !ctrl.More {
			break
		}
	}
	if messages < 2 {
		t.Fatalf("expected chunked filedata, got %d message(s)", messages)
	}
	decoded, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded, content) {
		t.Fatal("reassembled file differs")
	}
}

// An agent emitting one absurd (>maxAgentLine) line loses that line with a
// stderr notice — the read loop must survive and deliver the next line.
func TestOversizedAgentLineSkipped(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)
	client.control(Control{Op: "credit", Bytes: 8 << 20})

	inst := &agentInstance{
		ID:          "test",
		attached:    make(map[*session]struct{}),
		idMap:       make(map[string]clientReq),
		pendingByID: make(map[string]int),
		lineBufs:    make(map[*session][]byte),
	}
	inst.attached[client.sess] = struct{}{}

	notification := `{"jsonrpc":"2.0","method":"session/update","params":{}}`
	huge := strings.Repeat("z", maxAgentLine+1024)
	done := make(chan struct{})
	go func() {
		inst.readLoop(io.MultiReader(
			strings.NewReader(huge), strings.NewReader("\n"),
			strings.NewReader(notification+"\n")))
		close(done)
	}()

	sawNotice := false
	deadline := time.Now().Add(10 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for forwarded notification")
		}
		typ, payload := client.nextUnit(t, 10*time.Second)
		if typ == unitTypeControl {
			var c Control
			_ = json.Unmarshal(payload, &c)
			if c.Op == "stderr" && strings.Contains(c.Line, "dropped") {
				sawNotice = true
			}
			continue
		}
		if typ == unitTypeStdio && strings.Contains(string(payload), "session/update") {
			break // the loop survived the oversized line
		}
	}
	if !sawNotice {
		t.Fatal("expected a stderr notice for the dropped line")
	}
	<-done
}
