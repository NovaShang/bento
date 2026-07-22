package acphost

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/novashang/bento/desktop/internal/hostidentity"
	"github.com/novashang/bento/desktop/internal/relay"
	"golang.org/x/crypto/ssh"
)

// Options configures the acphost server.
type Options struct {
	Log        *slog.Logger
	Keys       *hostidentity.AuthorizedKeys
	HostSigner hostidentity.HostSigner
	DaemonID   string
	// StateFile persists the statekv (workspace structure) across daemon
	// restarts. Empty = in-memory only (tests).
	StateFile string
}

// Server accepts streams (relay or local unix socket) and manages the
// registry of persistent agent instances.
type Server struct {
	log      *slog.Logger
	keys     *hostidentity.AuthorizedKeys
	signer   hostidentity.HostSigner
	daemonID string

	mu          sync.Mutex
	relayCli    *relay.Client
	sessions    map[uint32]*session
	instances   map[string]*agentInstance
	nextLocalID uint32

	stateMu   sync.Mutex
	state     map[string]string // key → base64 blob (workspace structure)
	stateFile string
}

func New(opts Options) *Server {
	s := &Server{
		log:         opts.Log,
		keys:        opts.Keys,
		signer:      opts.HostSigner,
		daemonID:    opts.DaemonID,
		sessions:    make(map[uint32]*session),
		instances:   make(map[string]*agentInstance),
		nextLocalID: 1 << 30,
		state:       make(map[string]string),
		stateFile:   opts.StateFile,
	}
	s.loadState()
	return s
}

// loadState restores the statekv from disk (best effort).
func (s *Server) loadState() {
	if s.stateFile == "" {
		return
	}
	b, err := os.ReadFile(s.stateFile)
	if err != nil {
		return
	}
	var m map[string]string
	if json.Unmarshal(b, &m) == nil && m != nil {
		s.state = m
	}
}

// setState stores a value, persists, and fans statechanged out to every
// OTHER established stream so live clients re-pull. Last write wins.
func (s *Server) setState(key, data string, from *session) {
	s.stateMu.Lock()
	if data == "" {
		delete(s.state, key)
	} else {
		s.state[key] = data
	}
	if s.stateFile != "" {
		if b, err := json.Marshal(s.state); err == nil {
			_ = os.WriteFile(s.stateFile, b, 0o600)
		}
	}
	s.stateMu.Unlock()

	s.mu.Lock()
	peers := make([]*session, 0, len(s.sessions))
	for _, sess := range s.sessions {
		if sess != from {
			peers = append(peers, sess)
		}
	}
	s.mu.Unlock()
	for _, sess := range peers {
		sess.mu.Lock()
		ok := sess.established
		sess.mu.Unlock()
		if ok {
			sess.sendControl(Control{Op: "statechanged", Key: key})
		}
	}
}

func (s *Server) getState(key string) string {
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	return s.state[key]
}

// RebindRelay attaches the relay client (created after the server).
func (s *Server) RebindRelay(c *relay.Client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.relayCli = c
}

// OnOpen implements relay.StreamHandler.
func (s *Server) OnOpen(streamID uint32) (relay.StreamSink, error) {
	s.mu.Lock()
	cli := s.relayCli
	s.mu.Unlock()
	if cli == nil {
		return nil, fmt.Errorf("relay not bound")
	}
	return s.openWithWriter(streamID, cli.WriterFor(streamID)), nil
}

// openWithWriter builds an encrypted (relay) session.
func (s *Server) openWithWriter(streamID uint32, out io.Writer) *session {
	return s.newSession(streamID, out, false)
}

// openPlaintext builds a local session (unix socket; peer is the same
// user, no handshake or sealing).
func (s *Server) openPlaintext(out io.Writer) *session {
	s.mu.Lock()
	s.nextLocalID++
	id := s.nextLocalID
	s.mu.Unlock()
	sess := s.newSession(id, out, true)
	sess.mu.Lock()
	sess.established = true
	sess.mu.Unlock()
	return sess
}

func (s *Server) newSession(streamID uint32, out io.Writer, plaintext bool) *session {
	sess := &session{
		server:    s,
		log:       s.log.With("stream", streamID),
		streamID:  streamID,
		out:       out,
		plaintext: plaintext,
		window:    InitialWindow,
	}
	sess.windowCond = sync.NewCond(&sess.mu)
	s.mu.Lock()
	s.sessions[streamID] = sess
	s.mu.Unlock()
	sess.log.Info("acp stream opened", "plaintext", plaintext)
	return sess
}

func (s *Server) drop(streamID uint32) {
	s.mu.Lock()
	delete(s.sessions, streamID)
	s.mu.Unlock()
}

// ---- instance registry ----

func (s *Server) registerInstance(inst *agentInstance) {
	s.mu.Lock()
	s.instances[inst.ID] = inst
	s.mu.Unlock()
}

func (s *Server) instance(id string) *agentInstance {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.instances[id]
}

func (s *Server) listInstances() []InstanceInfo {
	s.mu.Lock()
	instances := make([]*agentInstance, 0, len(s.instances))
	for _, inst := range s.instances {
		instances = append(instances, inst)
	}
	s.mu.Unlock()
	rows := make([]InstanceInfo, 0, len(instances))
	for _, inst := range instances {
		rows = append(rows, inst.info())
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].CreatedAtUx < rows[j].CreatedAtUx })
	return rows
}

// gcExited keeps an exited instance listed for a grace period (so clients
// see the exit), then drops it.
func (s *Server) gcExited(inst *agentInstance) {
	time.AfterFunc(time.Hour, func() {
		s.mu.Lock()
		delete(s.instances, inst.ID)
		s.mu.Unlock()
	})
}

// deviceKey returns the raw Ed25519 key for a paired device id.
func (s *Server) deviceKey(deviceID string) (ed25519.PublicKey, bool) {
	for _, k := range s.keys.List() {
		if k.DeviceID != deviceID {
			continue
		}
		if cp, ok := k.PubKey.(ssh.CryptoPublicKey); ok {
			if ed, ok := cp.CryptoPublicKey().(ed25519.PublicKey); ok {
				return ed, true
			}
		}
	}
	return nil, false
}

// session is one stream: transport framing (+ crypto on relay streams) and
// the control surface. Agent processes live in agentInstance — closing a
// stream detaches, never kills.
type session struct {
	server    *Server
	log       *slog.Logger
	streamID  uint32
	out       io.Writer
	plaintext bool

	mu          sync.Mutex
	windowCond  *sync.Cond
	window      int64
	established bool
	closed      bool
	inbox       unitBuffer
	sealIn      *boxer // c2s: opens client units
	sealOut     *boxer // s2c: seals daemon units

	// stdioMu keeps one line's chunks contiguous on the wire: sendStdio
	// splits big lines into several units, and a concurrent sender (attach
	// replay vs. the instance read loop) must not interleave mid-line —
	// the client reassembles the byte stream on newlines.
	stdioMu sync.Mutex

	instance *agentInstance
}

// Write implements relay.StreamSink (bytes from the device).
func (t *session) Write(p []byte) (int, error) {
	units, err := t.inboxAppend(p)
	if err != nil {
		t.log.Warn("bad inbound framing", "err", err)
		_ = t.Close()
		return len(p), nil
	}
	for _, unit := range units {
		t.handleUnit(unit)
	}
	return len(p), nil
}

func (t *session) inboxAppend(p []byte) ([][]byte, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.inbox.append(p)
}

func (t *session) handleUnit(unit []byte) {
	t.mu.Lock()
	established := t.established
	t.mu.Unlock()
	if !established {
		t.handleHello(unit)
		return
	}

	var plain []byte
	if t.plaintext {
		plain = unit
	} else {
		t.mu.Lock()
		opened, err := t.sealIn.open(unit)
		t.mu.Unlock()
		if err != nil {
			t.log.Warn("failed to open sealed unit", "err", err)
			_ = t.Close()
			return
		}
		plain = opened
	}
	if len(plain) < 1 {
		return
	}
	switch plain[0] {
	case unitTypeControl:
		var c Control
		if err := json.Unmarshal(plain[1:], &c); err != nil {
			t.log.Warn("bad control json", "err", err)
			return
		}
		t.handleControl(c)
	case unitTypeStdio:
		t.mu.Lock()
		inst := t.instance
		t.mu.Unlock()
		if inst != nil {
			inst.handleClientStdio(t, plain[1:])
		}
	}
}

func (t *session) handleHello(unit []byte) {
	fail := func(reason string) {
		t.log.Warn("handshake rejected", "reason", reason)
		body, _ := json.Marshal(Welcome{Error: reason})
		_, _ = t.out.Write(prefixUnit(body))
		_ = t.Close()
	}

	var hello Hello
	if err := json.Unmarshal(unit, &hello); err != nil {
		fail("malformed hello")
		return
	}
	if hello.V != ProtocolV1 {
		fail(fmt.Sprintf("unsupported protocol %d", hello.V))
		return
	}
	skew := time.Since(time.Unix(hello.TS, 0))
	if skew < -HandshakeMaxSkewSec*time.Second || skew > HandshakeMaxSkewSec*time.Second {
		fail("timestamp outside allowed skew")
		return
	}
	devKey, ok := t.server.deviceKey(hello.DeviceID)
	if !ok {
		fail("unknown device")
		return
	}
	msg := helloSigMessage(t.server.daemonID, hello.DeviceID, hello.TS, hello.EphPub)
	if err := verifyEd25519(devKey, msg, hello.Sig); err != nil {
		fail("bad device signature")
		return
	}

	eph, err := newEphemeral()
	if err != nil {
		fail("internal: ephemeral key")
		return
	}
	shared, err := eph.shared(hello.EphPub)
	if err != nil {
		fail("bad ephemeral key")
		return
	}
	c2s, s2c, err := deriveKeys(shared, t.server.daemonID, hello.DeviceID)
	if err != nil {
		fail("internal: kdf")
		return
	}
	sealIn, err1 := newBoxer(c2s)
	sealOut, err2 := newBoxer(s2c)
	if err1 != nil || err2 != nil {
		fail("internal: cipher")
		return
	}

	hostEph := eph.publicB64()
	sig, err := t.server.signer.SignRaw(
		welcomeSigMessage(t.server.daemonID, hello.DeviceID, hello.TS, hello.EphPub, hostEph))
	if err != nil {
		fail("internal: sign")
		return
	}

	t.mu.Lock()
	t.sealIn = sealIn
	t.sealOut = sealOut
	t.established = true
	t.mu.Unlock()

	body, _ := json.Marshal(Welcome{
		V:       ProtocolV1,
		EphPub:  hostEph,
		HostPub: base64.StdEncoding.EncodeToString(t.server.signer.RawPublicKey()),
		Sig:     base64.StdEncoding.EncodeToString(sig),
	})
	_, _ = t.out.Write(prefixUnit(body))
	t.log.Info("acp handshake established", "device", hello.DeviceID)
}

func (t *session) handleControl(c Control) {
	switch c.Op {
	case "spawn":
		t.spawn(c)
	case "attach":
		t.attach(c)
	case "detach":
		t.mu.Lock()
		inst := t.instance
		t.instance = nil
		t.mu.Unlock()
		if inst != nil {
			inst.detach(t)
		}
		t.sendControl(Control{Op: "detached", AgentID: c.AgentID})
	case "list":
		t.sendControl(Control{Op: "agents", Agents: t.server.listInstances()})
	case "kill":
		var inst *agentInstance
		if c.AgentID != "" {
			inst = t.server.instance(c.AgentID)
		} else {
			t.mu.Lock()
			inst = t.instance
			t.mu.Unlock()
		}
		if inst != nil {
			inst.kill()
		}
	case "credit":
		if c.Bytes > 0 {
			t.mu.Lock()
			t.window += c.Bytes
			t.mu.Unlock()
			t.windowCond.Broadcast()
		}
	case "listdir":
		t.listDir(c.Path)
	case "readfile":
		t.readFile(c.Path)
	case "stat":
		t.statPath(c.Path, c.Cwd)
	case "listtree":
		t.listTree(c)
	case "readbytes":
		t.readBytes(c.Path, c.Bytes)
	case "setstate":
		t.server.setState(c.Key, c.Data, t)
	case "getstate":
		t.sendControl(Control{Op: "statedata", Key: c.Key, Data: t.server.getState(c.Key)})
	case "ping":
		t.sendControl(Control{Op: "pong"})
	default:
		t.log.Info("unknown control op", "op", c.Op)
	}
}

func (t *session) spawn(c Control) {
	t.mu.Lock()
	already := t.instance != nil
	t.mu.Unlock()
	if already {
		t.sendControl(Control{Op: "attachFailed", Error: "stream already attached to an agent"})
		return
	}
	inst, err := spawnInstance(c, t.server.gcExited)
	if err != nil {
		t.sendControl(Control{Op: "attachFailed", Error: err.Error()})
		return
	}
	t.server.registerInstance(inst)
	t.log.Info("agent spawned", "agent", inst.ID, "cmd", c.Cmd, "cwd", c.Cwd)
	t.bind(inst)
}

func (t *session) attach(c Control) {
	inst := t.server.instance(c.AgentID)
	if inst == nil {
		t.sendControl(Control{Op: "attachFailed", AgentID: c.AgentID, Error: "unknown agent"})
		return
	}
	t.mu.Lock()
	previous := t.instance
	t.mu.Unlock()
	if previous != nil && previous != inst {
		previous.detach(t)
	}
	t.bind(inst)
}

func (t *session) bind(inst *agentInstance) {
	t.mu.Lock()
	t.instance = inst
	t.window = InitialWindow
	t.mu.Unlock()
	t.windowCond.Broadcast()
	inst.attach(t)
}

func (t *session) listDir(path string) {
	dir := expandHome(path)
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = home
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.sendControl(Control{Op: "dirents", Path: dir, Error: err.Error()})
		return
	}
	out := make([]DirEntry, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		out = append(out, DirEntry{Name: name, Dir: e.IsDir()})
		if len(out) >= 500 {
			break
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Dir != out[j].Dir {
			return out[i].Dir
		}
		return out[i].Name < out[j].Name
	})
	t.sendControl(Control{Op: "dirents", Path: dir, Entries: out})
}

// readFile serves file-preview requests (the bento-file analogue): text
// files up to 2 MiB. The base64 payload is split across several filedata
// messages (more=true on all but the last) — a 2 MiB file base64-encodes
// past MaxUnit, and one oversized unit tears the whole transport.
func (t *session) readFile(path string) {
	full := expandHome(path)
	info, err := os.Stat(full)
	if err != nil {
		t.sendControl(Control{Op: "filedata", Path: full, Error: err.Error()})
		return
	}
	if info.IsDir() {
		t.sendControl(Control{Op: "filedata", Path: full, Error: "is a directory"})
		return
	}
	if info.Size() > 2<<20 {
		t.sendControl(Control{Op: "filedata", Path: full, Error: "file too large to preview (>2 MiB)"})
		return
	}
	data, err := os.ReadFile(full)
	if err != nil {
		t.sendControl(Control{Op: "filedata", Path: full, Error: err.Error()})
		return
	}
	if !utf8.Valid(data) {
		t.sendControl(Control{Op: "filedata", Path: full, Error: "binary file"})
		return
	}
	b64 := base64.StdEncoding.EncodeToString(data)
	for off := 0; off < len(b64) || off == 0; off += fileDataChunk {
		end := min(off+fileDataChunk, len(b64))
		t.sendControl(Control{
			Op: "filedata", Path: full,
			Data: b64[off:end], More: end < len(b64),
		})
	}
}

// resolvePreviewPath expands ~ and joins a relative path onto the pane's cwd,
// so the client can hand us "~/x", "/abs/x", or "rel/x" against a known cwd.
func resolvePreviewPath(path, cwd string) string {
	p := expandHome(path)
	if !filepath.IsAbs(p) && cwd != "" {
		p = filepath.Join(expandHome(cwd), p)
	}
	return filepath.Clean(p)
}

// statPath resolves + stats a path for the preview flow (SmartPathResolver's
// dumb pipe). Symlinks are followed so a link-to-file previews as its target.
func (t *session) statPath(path, cwd string) {
	full := resolvePreviewPath(path, cwd)
	if ev, err := filepath.EvalSymlinks(full); err == nil {
		full = ev
	}
	info, err := os.Stat(full)
	if err != nil {
		t.sendControl(Control{Op: "statdata", Path: full, Error: err.Error()})
		return
	}
	t.sendControl(Control{
		Op: "statdata", Path: full,
		Size: info.Size(), IsDir: info.IsDir(),
		IsRegular: info.Mode().IsRegular(), Mtime: info.ModTime().Unix(),
	})
}

// treeSkips mirrors the client's TreeListRequest.defaultSkipNames — heavy,
// machine-generated trees (a build/ dir) would otherwise drown the entry
// budget before the walk ever reached the source tree.
var treeSkipNames = map[string]bool{
	".git": true, "node_modules": true, ".build": true, ".swiftpm": true,
	"DerivedData": true, "Pods": true, "__pycache__": true, ".venv": true,
	"venv": true, ".cache": true, ".next": true, ".gradle": true, "target": true,
	"Build": true, "XCBuildData": true, "SourcePackages": true,
	"EagerLinkingTBDs": true, "SwiftExplicitPrecompiledModules": true,
	"ModuleCache": true, "dist": true, ".Trash": true,
}

var treeSkipSuffixes = []string{
	".noindex", ".app", ".xcarchive", ".framework", ".xcframework", ".dSYM",
}

func treeSkips(name string) bool {
	if treeSkipNames[name] {
		return true
	}
	for _, s := range treeSkipSuffixes {
		if strings.HasSuffix(name, s) {
			return true
		}
	}
	return false
}

// listTree serves the file-tree browser and SmartPathResolver's index: a
// bounded BFS under root (the port of the Swift LocalFileSource.listTree), with
// client-chosen bounds. A partial index is still a useful index.
func (t *session) listTree(c Control) {
	root := resolvePreviewPath(c.Path, c.Cwd)
	maxDepth := c.MaxDepth
	if maxDepth <= 0 {
		maxDepth = 4
	}
	maxEntries := c.MaxEntries
	if maxEntries <= 0 {
		maxEntries = 2000
	}
	maxDirs := c.MaxDirs
	if maxDirs <= 0 {
		maxDirs = 256
	}
	maxChildren := c.MaxChildren
	if maxChildren <= 0 {
		maxChildren = 200
	}
	deadline := time.Now().Add(1500 * time.Millisecond)

	type queued struct {
		rel   string
		depth int
	}
	queue := []queued{{"", 0}}
	out := make([]TreeEntry, 0, 256)
	dirsVisited := 0
	for len(queue) > 0 {
		if dirsVisited >= maxDirs || time.Now().After(deadline) {
			break
		}
		cur := queue[0]
		queue = queue[1:]
		dirsVisited++
		dir := root
		if cur.rel != "" {
			dir = filepath.Join(root, cur.rel)
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
		listed := 0
		for _, e := range entries {
			if listed >= maxChildren {
				break
			}
			listed++
			if len(out) >= maxEntries {
				t.sendControl(Control{Op: "treedata", Path: root, Tree: out})
				return
			}
			name := e.Name()
			childRel := name
			if cur.rel != "" {
				childRel = cur.rel + "/" + name
			}
			// A symlinked directory is listed but never descended into (loop
			// safety) — os.ReadDir reports the link type, so IsDir is false.
			isDir := e.IsDir()
			out = append(out, TreeEntry{Rel: childRel, Dir: isDir})
			if isDir && cur.depth+1 < maxDepth && !treeSkips(name) {
				queue = append(queue, queued{childRel, cur.depth + 1})
			}
		}
	}
	t.sendControl(Control{Op: "treedata", Path: root, Tree: out})
}

// readBytes reads up to maxBytes (≤20 MiB) of raw bytes from the head of a
// file and returns them base64-encoded — the image/binary path, where readfile
// (UTF-8, 2 MiB) refuses. Same chunking as readFile: no unit may breach MaxUnit.
func (t *session) readBytes(path string, maxBytes int64) {
	full := expandHome(path)
	if maxBytes <= 0 || maxBytes > 20<<20 {
		maxBytes = 20 << 20
	}
	info, err := os.Stat(full)
	if err != nil {
		t.sendControl(Control{Op: "filedata", Path: full, Error: err.Error()})
		return
	}
	if info.IsDir() {
		t.sendControl(Control{Op: "filedata", Path: full, Error: "is a directory"})
		return
	}
	f, err := os.Open(full)
	if err != nil {
		t.sendControl(Control{Op: "filedata", Path: full, Error: err.Error()})
		return
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxBytes))
	if err != nil {
		t.sendControl(Control{Op: "filedata", Path: full, Error: err.Error()})
		return
	}
	b64 := base64.StdEncoding.EncodeToString(data)
	for off := 0; off < len(b64) || off == 0; off += fileDataChunk {
		end := min(off+fileDataChunk, len(b64))
		t.sendControl(Control{
			Op: "filedata", Path: full,
			Data: b64[off:end], More: end < len(b64),
		})
	}
}

func (t *session) sendControl(c Control) {
	t.sendUnit(unitTypeControl, marshalControl(c))
}

// sendStdio forwards agent output, honoring the credit window (blocks the
// caller — the instance read loop — which backpressures the agent). Lines
// longer than StdioChunk are split into several units so no unit can breach
// the receiver's MaxUnit cap (which tears the whole transport); the client
// reassembles on newlines, so the split is invisible above the framing.
func (t *session) sendStdio(p []byte) {
	t.stdioMu.Lock()
	defer t.stdioMu.Unlock()
	for off := 0; off < len(p); off += StdioChunk {
		chunk := p[off:min(off+StdioChunk, len(p))]
		t.mu.Lock()
		for t.window <= 0 && !t.closed {
			t.windowCond.Wait()
		}
		if t.closed {
			t.mu.Unlock()
			return
		}
		t.window -= int64(len(chunk))
		t.mu.Unlock()
		t.sendUnit(unitTypeStdio, chunk)
	}
}

func (t *session) sendUnit(unitType byte, payload []byte) {
	t.mu.Lock()
	if t.closed || (!t.plaintext && t.sealOut == nil) {
		t.mu.Unlock()
		return
	}
	plain := make([]byte, 1+len(payload))
	plain[0] = unitType
	copy(plain[1:], payload)
	var body []byte
	if t.plaintext {
		body = plain
	} else {
		body = t.sealOut.seal(plain)
	}
	t.mu.Unlock()
	_, _ = t.out.Write(prefixUnit(body))
}

// Close implements relay.StreamSink: the stream is gone. The agent keeps
// running — detach, never kill (old tmux-detach semantics).
func (t *session) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	inst := t.instance
	t.instance = nil
	t.mu.Unlock()
	t.windowCond.Broadcast()
	if inst != nil {
		inst.detach(t)
	}
	t.server.drop(t.streamID)
	t.log.Info("acp stream closed (agent detached)")
	return nil
}

// ---- environment helpers ----

// augmentedEnv merges the daemon's environment with common tool install
// locations (launchd PATH is minimal) and the client-provided overrides.
func augmentedEnv(overrides map[string]string) []string {
	env := os.Environ()
	home, _ := os.UserHomeDir()
	extras := []string{
		"/opt/homebrew/bin", "/usr/local/bin",
		filepath.Join(home, ".local/bin"),
		filepath.Join(home, ".bun/bin"),
		filepath.Join(home, ".npm-global/bin"),
	}
	out := make([]string, 0, len(env)+len(overrides))
	seenPath := false
	for _, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			seenPath = true
			path := strings.TrimPrefix(kv, "PATH=")
			for _, extra := range extras {
				if !strings.Contains(path, extra) {
					path = extra + ":" + path
				}
			}
			kv = "PATH=" + path
		}
		out = append(out, kv)
	}
	if !seenPath {
		out = append(out, "PATH="+strings.Join(extras, ":")+":/usr/bin:/bin")
	}
	for k, v := range overrides {
		out = append(out, k+"="+v)
	}
	return out
}

func lookPath(cmd string, env []string) (string, error) {
	if strings.Contains(cmd, "/") {
		return expandHome(cmd), nil
	}
	var pathVar string
	for _, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			pathVar = strings.TrimPrefix(kv, "PATH=")
		}
	}
	for _, dir := range strings.Split(pathVar, ":") {
		candidate := filepath.Join(dir, cmd)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("%s not found in PATH", cmd)
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			return filepath.Join(home, strings.TrimPrefix(p, "~"))
		}
	}
	return p
}
