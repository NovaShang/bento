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

	"github.com/novashang/bento/daemon/internal/hostidentity"
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
	return newServerIn(t, t.TempDir(), registerDevice)
}

// newServerIn builds a server rooted at an explicit home dir, so a test can
// stand a SECOND server on the same disk state — that is what a daemon
// restart looks like from the conversations' point of view.
func newServerIn(t *testing.T, dir string, registerDevice bool) (*Server, ed25519.PrivateKey, ed25519.PublicKey) {
	t.Helper()

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
		Log:              slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn})),
		Keys:             keys,
		HostSigner:       hostWrap,
		DaemonID:         "daemon-test",
		ConversationRoot: filepath.Join(dir, "conversations"),
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

// stripSeq removes the daemon-stamped `"_seq":N,` scrollback prefix from a
// sequenced notification so literal comparisons keep working (injection
// re-marshals with sorted keys, which puts `_seq` first and leaves the
// rest in the tests' already-sorted literal order).
func stripSeq(line string) string {
	if !strings.HasPrefix(line, `{"_seq":`) {
		return line
	}
	if i := strings.Index(line, ","); i >= 0 {
		return "{" + line[i+1:]
	}
	return line
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
		if stripSeq(strings.TrimRight(string(payload), "\n")) == want {
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
		if typ == unitTypeStdio && stripSeq(strings.TrimSpace(string(payload))) == note {
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
	if got := stripSeq(b.nextStdioLine(t, 3*time.Second)); got != note {
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
	if got := stripSeq(b.nextStdioLine(t, 3*time.Second)); got != note {
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
	if got := stripSeq(a.nextStdioLine(t, 3*time.Second)); got != marker {
		t.Fatalf("duplicate answer leaked to agent: %q", got)
	}
	if got := stripSeq(b.nextStdioLine(t, 3*time.Second)); got != marker {
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
	if got := stripSeq(a.nextStdioLine(t, 3*time.Second)); got != bNote {
		t.Fatalf("expected B's line first, got %q", got)
	}

	// A completes its line; it comes through uncorrupted.
	a.stdioRaw([]byte("lit\"}\n"))
	want := `{"jsonrpc":"2.0","method":"a/split"}`
	if got := stripSeq(a.nextStdioLine(t, 3*time.Second)); got != want {
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

// ---- sequenced scrollback catch-up ----

// The original flashing bug: B catching up must NOT re-broadcast history to
// A. B gets the scrollback point-to-point, then joins live; A sees each
// line exactly once.
func TestCatchupReplayIsolatedFromCoViewers(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)

	// Three notifications stream while only A is attached.
	for i := 1; i <= 3; i++ {
		note := fmt.Sprintf(`{"jsonrpc":"2.0","method":"n/%d"}`, i)
		a.stdio(note)
		if got := stripSeq(a.nextStdioLine(t, 3*time.Second)); got != note {
			t.Fatalf("A missed its own echo: %q", got)
		}
	}

	// B attaches with a catch-up cursor of 0 → full replay, point-to-point.
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID, Catchup: true})
	ctrl := b.nextControl(t, 2*time.Second)
	if ctrl.Op != "attached" || !ctrl.Replay || ctrl.HeadSeq != 3 || ctrl.StartSeq != 1 {
		t.Fatalf("expected replay-granting attached, got %+v", ctrl)
	}
	for i := 1; i <= 3; i++ {
		line := b.nextStdioLine(t, 3*time.Second)
		want := fmt.Sprintf(`{"jsonrpc":"2.0","method":"n/%d"}`, i)
		if stripSeq(line) != want {
			t.Fatalf("replay line %d mismatch: %q", i, line)
		}
		if !strings.HasPrefix(line, fmt.Sprintf(`{"_seq":%d,`, i)) {
			t.Fatalf("replay line %d missing seq stamp: %q", i, line)
		}
	}

	// A must have seen NONE of that replay.
	select {
	case u := <-a.out.units:
		t.Fatalf("A received unexpected unit during B's catch-up: %q", u)
	case <-time.After(300 * time.Millisecond):
	}

	// B is live now: the next note reaches both, exactly once.
	note := `{"jsonrpc":"2.0","method":"n/live"}`
	a.stdio(note)
	if got := stripSeq(a.nextStdioLine(t, 3*time.Second)); got != note {
		t.Fatalf("A missed live note: %q", got)
	}
	live := b.nextStdioLine(t, 3*time.Second)
	if stripSeq(live) != note || !strings.HasPrefix(live, `{"_seq":4,`) {
		t.Fatalf("B missed live note after join: %q", live)
	}
	select {
	case u := <-b.out.units:
		t.Fatalf("B saw a duplicate: %q", u)
	case <-time.After(200 * time.Millisecond):
	}
}

// A warm reconnect replays only the missing tail.
func TestCatchupDeltaReplay(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	for i := 1; i <= 3; i++ {
		a.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","method":"n/%d"}`, i))
		_ = a.nextStdioLine(t, 3*time.Second)
	}

	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID, Catchup: true, HaveSeq: 2})
	if ctrl := b.nextControl(t, 2*time.Second); !ctrl.Replay {
		t.Fatalf("expected replay, got %+v", ctrl)
	}
	line := b.nextStdioLine(t, 3*time.Second)
	if !strings.HasPrefix(line, `{"_seq":3,`) {
		t.Fatalf("expected only seq 3, got %q", line)
	}
	select {
	case u := <-b.out.units:
		t.Fatalf("delta replay over-delivered: %q", u)
	case <-time.After(200 * time.Millisecond):
	}
}

// An up-to-date cursor (and a legacy attach) gets no replay.
func TestCatchupNoReplayWhenCurrent(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	a.stdio(`{"jsonrpc":"2.0","method":"n/1"}`)
	_ = a.nextStdioLine(t, 3*time.Second)

	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID, Catchup: true, HaveSeq: 1})
	if ctrl := b.nextControl(t, 2*time.Second); ctrl.Replay || ctrl.HeadSeq != 1 {
		t.Fatalf("expected no-replay attach, got %+v", ctrl)
	}

	legacy := newPlainClient(server)
	legacy.control(Control{Op: "attach", AgentID: agentID})
	if ctrl := legacy.nextControl(t, 2*time.Second); ctrl.Replay {
		t.Fatalf("legacy attach must not be granted replay: %+v", ctrl)
	}
}

// stalledCatchup parks a fresh client mid-replay: it fills the scrollback
// past the credit window, then attaches with a zero cursor and never grants
// credit, so the replay blocks before the join. Anything the daemon sends
// point-to-point to the ATTACHED set in the meantime misses this stream.
// `a` (the already-attached client) is credited generously first — a blocked
// co-viewer would backpressure the agent's read loop and stall the setup.
func stalledCatchup(t *testing.T, server *Server, a *plainClient, agentID string) *plainClient {
	t.Helper()
	a.control(Control{Op: "credit", Bytes: 8 << 20})
	pad := strings.Repeat("x", 4096)
	for i := 0; i < InitialWindow/4096+32; i++ {
		a.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","method":"n/%d","params":{"pad":"%s"}}`, i, pad))
		_ = a.nextStdioLine(t, 3*time.Second)
	}
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID, Catchup: true})
	ctrl := b.nextControl(t, 2*time.Second)
	if ctrl.Op != "attached" || !ctrl.Replay {
		t.Fatalf("expected replay-granting attach, got %+v", ctrl)
	}
	return b
}

// A turn that ends while a catch-up replay is still draining must reach that
// stream once it joins. It was told `turn_active: true` on attach, and the
// prompt response goes only to the origin (a connection it doesn't own —
// across an app restart, one that no longer exists), so a dropped turnDone
// leaves the pane running a turn forever, with a cancel finding nothing live.
func TestTurnDoneAfterStalledCatchupReplay(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)

	// A prompts (id 5 → agent id 1); cat echoes it back as an agent request.
	a.stdio(`{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{}}`)
	_ = a.nextStdioLine(t, 3*time.Second)

	b := stalledCatchup(t, server, a, agentID)

	// The turn finishes while B is parked mid-replay.
	a.stdio(`{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}`)
	resp := a.nextStdioLine(t, 3*time.Second)
	if !strings.Contains(resp, `"id":5`) {
		t.Fatalf("expected prompt response on A, got %q", resp)
	}

	// Credit releases the replay; the join must carry the missed turn end.
	b.control(Control{Op: "credit", Bytes: 8 << 20})
	ctrl := b.nextControl(t, 5*time.Second)
	if ctrl.Op != "turnDone" || ctrl.Line != "end_turn" {
		t.Fatalf("expected turnDone after replay join, got %+v", ctrl)
	}
}

// Same window, same hole: an agent that dies mid-replay must not look alive
// to the stream that joins after it.
func TestExitAfterStalledCatchupReplay(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	b := stalledCatchup(t, server, a, agentID)

	a.control(Control{Op: "kill"})
	b.control(Control{Op: "credit", Bytes: 8 << 20})
	deadline := time.Now().Add(5 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatal("no exit control after replay join")
		}
		if ctrl := b.nextControl(t, 5*time.Second); ctrl.Op == "exit" {
			return
		}
	}
}

// A catchup stream's session/load is answered from the cached session
// result — the agent never sees it (no re-replay, turn-safe).
func TestCatchupSessionLoadServedFromCache(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)

	// Prime the cache: session/new round-trips through cat.
	a.stdio(`{"jsonrpc":"2.0","id":9,"method":"session/new","params":{"cwd":"/tmp"}}`)
	echoed := a.nextStdioLine(t, 3*time.Second)
	var er rpcShape
	_ = json.Unmarshal([]byte(echoed), &er)
	a.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"sess-1","modes":{"currentModeId":"code"}}}`, er.ID))
	if resp := a.nextStdioLine(t, 3*time.Second); !strings.Contains(resp, `"id":9`) {
		t.Fatalf("expected session/new response, got %q", resp)
	}

	// One logged notification so the log is non-empty (replay grantable).
	a.stdio(`{"jsonrpc":"2.0","method":"n/1"}`)
	_ = a.nextStdioLine(t, 3*time.Second)

	// B catches up, then asks session/load: answered from cache, instantly.
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID, Catchup: true})
	if ctrl := b.nextControl(t, 2*time.Second); !ctrl.Replay {
		t.Fatalf("expected replay, got %+v", ctrl)
	}
	_ = b.nextStdioLine(t, 3*time.Second) // the replayed n/1
	b.stdio(`{"jsonrpc":"2.0","id":7,"method":"session/load","params":{"sessionId":"sess-1"}}`)
	resp := b.nextStdioLine(t, 3*time.Second)
	if !strings.Contains(resp, `"id":7`) || !strings.Contains(resp, `"sessionId":"sess-1"`) {
		t.Fatalf("expected cached load response, got %q", resp)
	}
	// The agent (cat) never saw the load — nothing echoes to A.
	select {
	case u := <-a.out.units:
		t.Fatalf("session/load leaked to the agent: %q", u)
	case <-time.After(300 * time.Millisecond):
	}
}

// ---- multi-viewer turn and approval state ----

// A co-viewer learns a turn STARTED, not just that one finished. Without it
// the other device shows an idle pane while output streams in, and lets the
// user fire a second concurrent prompt at the same agent.
func TestTurnStartedBroadcastToObservers(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)

	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	if ctrl := b.nextControl(t, 2*time.Second); ctrl.Op != "attached" {
		t.Fatalf("attach failed: %+v", ctrl)
	}

	a.stdio(`{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s"}}`)
	if ctrl := b.nextControl(t, 3*time.Second); ctrl.Op != "turnStarted" || ctrl.AgentID != agentID {
		t.Fatalf("co-viewer did not learn the turn started: %+v", ctrl)
	}
	// The prompting client is not told what it already knows.
	if line := a.nextStdioLine(t, 3*time.Second); !strings.Contains(line, "session/prompt") {
		t.Fatalf("expected the forwarded prompt, got %q", line)
	}
}

// The first answer to an agent request wins — and everyone else is told, so
// the card they are still showing goes away instead of poisoning the next
// request's slot.
func TestRequestAnsweredBroadcastToOtherViewers(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	_ = b.nextControl(t, 2*time.Second)

	// cat echoes this back, so the daemon sees an agent→client request and
	// broadcasts it to both viewers.
	a.stdio(`{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{}}`)
	var agentReqID string
	for _, c := range []*plainClient{a, b} {
		line := c.nextStdioLine(t, 3*time.Second)
		if !strings.Contains(line, "request_permission") {
			t.Fatalf("viewer missed the permission request, got %q", line)
		}
		// The id every viewer sees is the daemon's own: client→agent ids are
		// rewritten, and cat's echo carries the rewritten one back.
		var shape rpcShape
		_ = json.Unmarshal([]byte(line), &shape)
		agentReqID = string(shape.ID)
	}

	// A answers; B must be told, exactly once, with that same id.
	a.stdio(fmt.Sprintf(
		`{"jsonrpc":"2.0","id":%s,"result":{"outcome":{"outcome":"selected","optionId":"allow"}}}`,
		agentReqID))
	ctrl := b.nextControl(t, 3*time.Second)
	if ctrl.Op != "requestAnswered" || ctrl.RequestID != agentReqID {
		t.Fatalf("expected requestAnswered for %s, got %+v", agentReqID, ctrl)
	}

	// A late duplicate answer from B is dropped: it must not reach the agent
	// (which already moved on) and must not produce a second broadcast.
	b.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","id":%s,"result":{"outcome":{"outcome":"cancelled"}}}`, agentReqID))
	select {
	case u := <-b.out.units:
		t.Fatalf("the dropped duplicate produced traffic: %q", u)
	case <-time.After(300 * time.Millisecond):
	}
}

// A request about the Mac's filesystem is answered BY the Mac. It must not
// be shown to viewers: a phone has no such file, and with first-answer-wins
// its refusal would be the one the agent gets.
func TestHostSideRequestsNeverReachViewers(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	_ = b.nextControl(t, 2*time.Second)

	// cat echoes this, so the daemon sees the agent asking to read a file.
	a.stdio(`{"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{"path":"/etc/hosts"}}`)

	// The daemon answers the agent directly — cat echoes that answer back to
	// the requesting stream, and it is an error, not a viewer's reply.
	line := a.nextStdioLine(t, 3*time.Second)
	if !strings.Contains(line, "-32601") || !strings.Contains(line, "fs not supported") {
		t.Fatalf("expected the host to decline the fs request, got %q", line)
	}
	// B, which cannot answer for this machine, never sees it.
	select {
	case u := <-b.out.units:
		t.Fatalf("host-side request leaked to a viewer: %q", u)
	case <-time.After(300 * time.Millisecond):
	}
}

// A pane whose project directory is gone (moved, deleted, or carrying a path
// from another machine) must say so. Go reports a chdir failure as
// "fork/exec <binary>: no such file or directory", which reads as a missing
// agent and sends everyone looking in the wrong place.
func TestMissingWorkingDirectoryIsReportedAsSuch(t *testing.T) {
	server, _, _ := newServer(t, true)
	p := newPlainClient(server)
	p.control(Control{Op: "spawn", Cmd: "/bin/cat", Cwd: "/var/mobile/Containers/Data/Application/nope"})
	ctrl := p.nextControl(t, 3*time.Second)
	if ctrl.Op != "attachFailed" {
		t.Fatalf("expected the spawn to fail, got %+v", ctrl)
	}
	if !strings.Contains(ctrl.Error, "working directory not found") {
		t.Fatalf("error blames the wrong thing: %q", ctrl.Error)
	}
}

// ---- durable conversations ----

// spawnConversation spawns /bin/cat bound to a named conversation, asking
// for catch-up the way a real client does, and returns the attach ack.
func spawnConversation(t *testing.T, p *plainClient, conversationID string, haveSeq uint64) Control {
	t.Helper()
	p.control(Control{
		Op: "spawn", Cmd: "/bin/cat", SessionID: conversationID,
		HaveSeq: haveSeq, Catchup: true,
	})
	ctrl := p.nextControl(t, 3*time.Second)
	if ctrl.Op != "attached" {
		t.Fatalf("expected attached, got %+v", ctrl)
	}
	return ctrl
}

// A transcript outlives the daemon: a second server on the same home replays
// the previous process's updates from disk, with seqs continuing where they
// stopped. Before the durable log this was a hard reset — every client had
// to rebuild through a full session/load.
func TestConversationLogSurvivesDaemonRestart(t *testing.T) {
	home := t.TempDir()
	first, _, _ := newServerIn(t, home, true)
	a := newPlainClient(first)
	spawnConversation(t, a, "conv-restart", 0)
	for i := 1; i <= 3; i++ {
		a.stdio(fmt.Sprintf(`{"jsonrpc":"2.0","method":"n/%d"}`, i))
		_ = a.nextStdioLine(t, 3*time.Second)
	}

	// The daemon goes away; the conversation's history does not.
	second, _, _ := newServerIn(t, home, true)
	b := newPlainClient(second)
	ack := spawnConversation(t, b, "conv-restart", 0)
	if !ack.Replay || ack.HeadSeq != 3 {
		t.Fatalf("expected replay of 3 durable updates, got %+v", ack)
	}
	for i := 1; i <= 3; i++ {
		line := b.nextStdioLine(t, 3*time.Second)
		if !strings.Contains(line, fmt.Sprintf(`"method":"n/%d"`, i)) {
			t.Fatalf("update %d not replayed from disk, got %q", i, line)
		}
	}

	// Seqs continue past the recovered head rather than restarting at 1 —
	// a client's cursor from before the restart stays meaningful. The exact
	// number is NOT ours to assert: the daemon's own resume bootstrap
	// (restore.go) races this write into the same log, and /bin/cat echoes
	// those frames back as updates — something a real agent never does. So
	// scan past any echoed bootstrap frames for OUR line and judge the seq
	// it carries.
	b.stdio(`{"jsonrpc":"2.0","method":"n/4"}`)
	for i := 0; ; i++ {
		if i >= 5 {
			t.Fatal("n/4 never came back")
		}
		line := b.nextStdioLine(t, 3*time.Second)
		if !strings.Contains(line, `"method":"n/4"`) {
			continue
		}
		var env struct {
			Seq uint64 `json:"_seq"`
		}
		if err := json.Unmarshal([]byte(line), &env); err != nil {
			t.Fatalf("unparseable update %q: %v", line, err)
		}
		if env.Seq < 4 {
			t.Fatalf("seq restarted instead of continuing: %q", line)
		}
		break
	}
}

// Two devices opening the same pane must not get two agents. The second
// spawn adopts the live process (and catches up from its log) instead of
// starting a rival that would replay and write the same conversation.
func TestSpawnAdoptsLiveConversation(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	first := spawnConversation(t, a, "conv-shared", 0)
	a.stdio(`{"jsonrpc":"2.0","method":"n/1"}`)
	_ = a.nextStdioLine(t, 3*time.Second)

	b := newPlainClient(server)
	second := spawnConversation(t, b, "conv-shared", 0)
	if second.AgentID != first.AgentID {
		t.Fatalf("second spawn started a rival agent: %s vs %s", second.AgentID, first.AgentID)
	}
	if !second.Replay {
		t.Fatalf("adopted spawn should catch up from the log, got %+v", second)
	}
	if line := b.nextStdioLine(t, 3*time.Second); !strings.Contains(line, `"method":"n/1"`) {
		t.Fatalf("adopted client missed the backlog, got %q", line)
	}
	if n := len(server.listInstances()); n != 1 {
		t.Fatalf("expected exactly one instance for the conversation, got %d", n)
	}

	// Both streams are live co-viewers of the one agent.
	a.stdio(`{"jsonrpc":"2.0","method":"n/2"}`)
	for _, c := range []*plainClient{a, b} {
		if line := c.nextStdioLine(t, 3*time.Second); !strings.Contains(line, `"method":"n/2"`) {
			t.Fatalf("co-viewer missed a live update, got %q", line)
		}
	}
}

// An unnamed spawn keeps its own process: two fresh conversations are two
// agents, and only a named one is adopted.
func TestSpawnWithoutConversationIsAlwaysFresh(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	b := newPlainClient(server)
	if a.spawnCat(t) == b.spawnCat(t) {
		t.Fatal("unnamed spawns must not be collapsed into one agent")
	}
}

// A client that spawns unnamed and only then loads a conversation someone
// else is already running must not become a second writer of that
// conversation's log — one file, one seq stream.
func TestSecondProcessNeverWritesAnOwnedConversationLog(t *testing.T) {
	server, _, _ := newServer(t, true)
	owner := newPlainClient(server)
	ownerAck := spawnConversation(t, owner, "conv-owned", 0)

	// The legacy shape: spawn with no conversation, then load one.
	late := newPlainClient(server)
	lateID := late.spawnCat(t)
	late.stdio(`{"jsonrpc":"2.0","id":1,"method":"session/load","params":{"sessionId":"conv-owned"}}`)
	_ = late.nextStdioLine(t, 3*time.Second) // cat echoes the forwarded request

	lateInst := server.instance(lateID)
	if lateInst == nil {
		t.Fatal("late instance vanished")
	}
	lateInst.mu.Lock()
	dir := lateInst.updates.dir
	lateInst.mu.Unlock()
	if dir != "" {
		t.Fatalf("second process bound the owned conversation's log: %s", dir)
	}

	// The owner keeps it, and keeps writing to it.
	ownerInst := server.instance(ownerAck.AgentID)
	ownerInst.mu.Lock()
	ownerDir := ownerInst.updates.dir
	ownerInst.mu.Unlock()
	if ownerDir == "" {
		t.Fatal("the owning process lost its durable log")
	}
}

// A cursor at the log head does NOT mean the client is holding a transcript,
// and the daemon must not act as if it does. Suppressing a rebuild's replay
// on that basis blanked every pane on a real workspace: the client had the
// cursor (bytes delivered) but no rendered history, asked for a rebuild, and
// got silence back. The cursor says what to SEND; only the client knows what
// it rendered.
func TestCursorAtHeadStillGetsTheHistoryItAsksFor(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	a.stdio(`{"jsonrpc":"2.0","method":"n/1"}`)
	_ = a.nextStdioLine(t, 3*time.Second)

	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID, Catchup: true, HaveSeq: 1})
	ack := b.nextControl(t, 2*time.Second)
	if ack.Replay || ack.HeadSeq != 1 {
		t.Fatalf("expected a no-replay attach at the head, got %+v", ack)
	}

	b.stdio(`{"jsonrpc":"2.0","id":5,"method":"session/load","params":{"sessionId":"sess-x"}}`)
	for _, c := range []*plainClient{a, b} {
		if line := c.nextStdioLine(t, 3*time.Second); !strings.Contains(line, `"method":"session/load"`) {
			t.Fatalf("expected the echoed load request, got %q", line)
		}
	}
	a.stdio(`{"jsonrpc":"2.0","method":"session/update","params":{"restored":true}}`)

	if line := b.nextStdioLine(t, 3*time.Second); !strings.Contains(line, `"restored":true`) {
		t.Fatalf("the rebuilding client was starved of its own replay: %q", line)
	}
}

// A rebuilding client's session/load replay is for that client alone: a
// co-viewer already holding the transcript must not have it delivered twice.
func TestUnloggedLoadReplayIsNotBroadcast(t *testing.T) {
	server, _, _ := newServer(t, true)
	a := newPlainClient(server)
	agentID := a.spawnCat(t)
	a.stdio(`{"jsonrpc":"2.0","method":"n/1"}`)
	_ = a.nextStdioLine(t, 3*time.Second)

	// B is a REBUILDING client: a legacy attach with no cursor at all, so
	// the daemon cannot know it holds anything. (A client whose cursor is at
	// the head is a different case — see
	// TestCurrentCursorSuppressesTheRestoreReplay.)
	b := newPlainClient(server)
	b.control(Control{Op: "attach", AgentID: agentID})
	if ctrl := b.nextControl(t, 2*time.Second); ctrl.Replay {
		t.Fatalf("a legacy attach must not be granted a replay: %+v", ctrl)
	}

	// B rebuilds via session/load; the log is non-empty so the replay is
	// unlogged, and it belongs to B only.
	b.stdio(`{"jsonrpc":"2.0","id":5,"method":"session/load","params":{"sessionId":"sess-x"}}`)
	// cat echoes the forwarded request, which reads as an agent→client
	// request and is broadcast to both viewers; drain it from each.
	for _, c := range []*plainClient{a, b} {
		if line := c.nextStdioLine(t, 3*time.Second); !strings.Contains(line, `"method":"session/load"`) {
			t.Fatalf("expected the echoed load request, got %q", line)
		}
	}
	// Now the "agent" streams the load's replay.
	a.stdio(`{"jsonrpc":"2.0","method":"session/update","params":{"replayed":true}}`)

	if line := b.nextStdioLine(t, 3*time.Second); !strings.Contains(line, `"replayed":true`) {
		t.Fatalf("the rebuilding client missed its own replay, got %q", line)
	}
	select {
	case u := <-a.out.units:
		t.Fatalf("rebuild replay leaked to a co-viewer: %q", u)
	case <-time.After(300 * time.Millisecond):
	}
}

// ---- bento-file API (iOS preview): stat / listtree / readbytes ----

func TestStat(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)

	dir := t.TempDir()
	path := filepath.Join(dir, "hello.txt")
	_ = os.WriteFile(path, []byte("hello world"), 0o644) // 11 bytes

	// Absolute path → resolved stat. (t.TempDir sits under a /var→/private/var
	// symlink on macOS, so match the basename, not the full path.)
	client.control(Control{Op: "stat", Path: path})
	ctrl := client.nextControl(t, 2*time.Second)
	if ctrl.Op != "statdata" || ctrl.Error != "" {
		t.Fatalf("unexpected: %+v", ctrl)
	}
	if !ctrl.IsRegular || ctrl.IsDir || ctrl.Size != 11 {
		t.Fatalf("bad stat: isReg=%v isDir=%v size=%d", ctrl.IsRegular, ctrl.IsDir, ctrl.Size)
	}
	if !strings.HasSuffix(ctrl.Path, "hello.txt") {
		t.Fatalf("resolved path missing basename: %q", ctrl.Path)
	}

	// Relative path resolves against cwd.
	client.control(Control{Op: "stat", Path: "hello.txt", Cwd: dir})
	ctrl = client.nextControl(t, 2*time.Second)
	if ctrl.Op != "statdata" || ctrl.Error != "" || ctrl.Size != 11 {
		t.Fatalf("cwd-relative stat failed: %+v", ctrl)
	}

	// Directory.
	client.control(Control{Op: "stat", Path: dir})
	ctrl = client.nextControl(t, 2*time.Second)
	if !ctrl.IsDir || ctrl.IsRegular {
		t.Fatalf("expected directory: %+v", ctrl)
	}

	// Missing → error, not a crash.
	client.control(Control{Op: "stat", Path: filepath.Join(dir, "nope")})
	ctrl = client.nextControl(t, 2*time.Second)
	if ctrl.Op != "statdata" || ctrl.Error == "" {
		t.Fatalf("expected error for missing file: %+v", ctrl)
	}
}

func TestListTree(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)

	dir := t.TempDir()
	_ = os.MkdirAll(filepath.Join(dir, "src"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "src", "main.go"), []byte("package main"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "README.md"), []byte("hi"), 0o644)
	// A skip dir: listed, but never descended into (would drown the budget).
	_ = os.MkdirAll(filepath.Join(dir, "node_modules", "pkg"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "node_modules", "pkg", "index.js"), []byte("x"), 0o644)

	client.control(Control{Op: "listtree", Path: dir})
	ctrl := client.nextControl(t, 2*time.Second)
	if ctrl.Op != "treedata" || ctrl.Error != "" {
		t.Fatalf("unexpected: %+v", ctrl)
	}
	isDir := map[string]bool{}
	present := map[string]bool{}
	for _, e := range ctrl.Tree {
		present[e.Rel] = true
		isDir[e.Rel] = e.Dir
	}
	if !present["src/main.go"] || !present["README.md"] {
		t.Fatalf("nested/root files missing: %+v", ctrl.Tree)
	}
	if !present["src"] || !isDir["src"] {
		t.Fatalf("src should be a listed directory")
	}
	if !present["node_modules"] {
		t.Fatalf("skip dir should still be listed")
	}
	if present["node_modules/pkg/index.js"] {
		t.Fatalf("skip dir was descended into — child leaked: %+v", ctrl.Tree)
	}
}

func TestReadBytes(t *testing.T) {
	server, _, _ := newServer(t, true)
	client := newPlainClient(server)

	dir := t.TempDir()
	path := filepath.Join(dir, "img.bin")
	// Non-UTF8 bytes (NUL + high bytes): readfile rejects these, readbytes
	// must return them intact — the image path.
	raw := []byte{0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x01, 0x02}
	_ = os.WriteFile(path, raw, 0o644)

	client.control(Control{Op: "readbytes", Path: path, Bytes: 1024})
	ctrl := client.nextControl(t, 2*time.Second)
	if ctrl.Op != "filedata" || ctrl.Error != "" {
		t.Fatalf("unexpected: %+v", ctrl)
	}
	decoded, _ := base64.StdEncoding.DecodeString(ctrl.Data)
	if !bytes.Equal(decoded, raw) {
		t.Fatalf("bytes mismatch: %x != %x", decoded, raw)
	}

	// maxBytes truncates to the head.
	client.control(Control{Op: "readbytes", Path: path, Bytes: 4})
	ctrl = client.nextControl(t, 2*time.Second)
	decoded, _ = base64.StdEncoding.DecodeString(ctrl.Data)
	if !bytes.Equal(decoded, raw[:4]) {
		t.Fatalf("truncated read wrong: %x", decoded)
	}

	// A directory → error, not a crash.
	client.control(Control{Op: "readbytes", Path: dir, Bytes: 1024})
	ctrl = client.nextControl(t, 2*time.Second)
	if ctrl.Error == "" {
		t.Fatalf("expected error reading a directory: %+v", ctrl)
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
		ID:              "test",
		attached:        make(map[*session]bool),
		idMap:           make(map[string]clientReq),
		pendingByID:     make(map[string]int),
		lineBufs:        make(map[*session][]byte),
		unloggedTargets: make(map[*session]int),
		updates:         newEventLog(nil),
	}
	inst.attached[client.sess] = false

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

// AgentCounts backs the number the Mac app quotes before it restarts the
// daemon ("this ends N running agent sessions"). A count that silently stayed
// at zero would turn a destructive action into a shrug, so pin both halves:
// alive, and mid-turn.
func TestAgentCountsTracksLiveAndBusyAgents(t *testing.T) {
	server, _, _ := newServer(t, true)
	if live, busy := server.AgentCounts(); live != 0 || busy != 0 {
		t.Fatalf("fresh server: live=%d busy=%d, want 0/0", live, busy)
	}

	client := newPlainClient(server)
	client.spawnCat(t)
	if live, busy := server.AgentCounts(); live != 1 || busy != 0 {
		t.Fatalf("after spawn: live=%d busy=%d, want 1/0", live, busy)
	}

	// A prompt in flight is exactly what "mid-turn" means on the wire.
	client.stdio(`{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s"}}`)
	waitFor(t, 3*time.Second, "the agent to count as busy", func() bool {
		live, busy := server.AgentCounts()
		return live == 1 && busy == 1
	})

	// A dead agent stays listed for its grace period but must stop counting —
	// otherwise the warning inflates and the user declines an update they
	// could have taken for free.
	client.control(Control{Op: "kill"})
	waitFor(t, 5*time.Second, "the killed agent to stop counting", func() bool {
		live, busy := server.AgentCounts()
		return live == 0 && busy == 0
	})
}
