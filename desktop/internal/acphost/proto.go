// Package acphost runs ACP agent processes on behalf of paired devices.
// Each relay stream carries one agent's stdio, end-to-end encrypted so the
// relay never sees plaintext (the role SSH played in the terminal version).
//
// # Stream wire protocol (inside relay data frames, both directions)
//
// Every unit is length-prefixed: 4-byte big-endian length + body. Relay
// frame boundaries carry no meaning.
//
// Handshake (plaintext, exactly one unit each way):
//
//  1. client → daemon: JSON Hello{v, device_id, ts, eph_pub, sig}
//     sig = Ed25519(device key, "bento-acp-hello:v1:<daemon_id>:<device_id>:<ts>:<eph_pub_b64>")
//  2. daemon → client: JSON Welcome{v, eph_pub, sig}
//     sig = Ed25519(host key, "bento-acp-welcome:v1:<daemon_id>:<device_id>:<ts>:<client_eph_b64>:<host_eph_b64>")
//     (or JSON {"error": "..."} followed by stream close)
//
// Both identity keys were exchanged at pairing time: the device key lives in
// the daemon's authorized store; the host key fingerprint is pinned on the
// device. Ephemeral X25519 keys are signed by those identities, so the relay
// cannot MITM. Session keys: HKDF-SHA256(X25519 shared secret,
// salt="bento-acp-v1:<daemon_id>:<device_id>", info="c2s"/"s2c") → 32 bytes
// each direction.
//
// After the handshake every unit body is a ChaCha20-Poly1305 box. Nonce =
// 4 zero bytes + 8-byte little-endian per-direction counter starting at 0.
// Sealed plaintext = 1 type byte + payload:
//
//	0x01 control: JSON (ops below)
//	0x02 stdio:   raw agent stdin/stdout bytes (newline-delimited JSON-RPC)
//
// Control ops client → daemon:
//
//	{"op":"spawn","cmd":"opencode","args":["acp"],"cwd":"/p","env":{"K":"V"}}
//	{"op":"kill"}                      terminate the agent
//	{"op":"credit","bytes":N}          add N bytes to the stdio send window
//	{"op":"listdir","path":"/p"}       browse host directories (cwd picker)
//	{"op":"ping"}
//
// Control ops daemon → client:
//
//	{"op":"spawned"}
//	{"op":"exit","code":N,"error":"…"} agent exited (error optional)
//	{"op":"stderr","line":"…"}         agent stderr, line-buffered
//	{"op":"dirents","path":"/p","entries":[{"name":"src","dir":true},…]}
//	{"op":"pong"}
//
// Flow control: only daemon→client stdio is windowed (tool output can
// burst; the client's prompts are tiny). The window starts at
// InitialWindow; the daemon stops reading agent stdout when it reaches 0,
// which backpressures the agent through the pipe. Client→daemon stdio
// backpressures naturally through the child's stdin pipe.
package acphost

import "encoding/json"

const (
	// ProtocolV1 is the acphost stream protocol version.
	ProtocolV1 = 1

	// InitialWindow is the daemon→client stdio window before any credit.
	InitialWindow = 256 * 1024

	// MaxUnit bounds a single length-prefixed unit (sanity limit). This is
	// a RECEIVE-side tear-down: senders must never emit a bigger unit, so
	// anything that can carry a large payload (stdio lines, filedata) is
	// chunked below the cap at the sender.
	MaxUnit = 1 << 20

	// StdioChunk is the maximum stdio payload per unit. One JSON-RPC line
	// spans multiple units when longer; both receive sides reassemble on
	// newlines, so chunk boundaries carry no meaning. ≤ InitialWindow, so
	// a single chunk always fits the credit window.
	StdioChunk = 256 * 1024

	// fileDataChunk is the max base64 payload per `filedata` control
	// message (the control channel has no credit window, so keep bursts
	// modest and every unit well under MaxUnit).
	fileDataChunk = 512 * 1024

	// maxAgentLine bounds a single JSON-RPC line from the agent (and a
	// client's buffered partial line). Longer lines are dropped with a
	// stderr notice — never by killing the read loop or the stream.
	maxAgentLine = 32 << 20

	// HandshakeMaxSkewSec bounds |now - hello.ts| (phone clocks drift).
	HandshakeMaxSkewSec = 90

	unitTypeControl byte = 0x01
	unitTypeStdio   byte = 0x02
)

// Hello is the client's handshake unit.
type Hello struct {
	V        int    `json:"v"`
	DeviceID string `json:"device_id"`
	TS       int64  `json:"ts"`
	EphPub   string `json:"eph_pub"` // base64 X25519 public key (32 bytes)
	Sig      string `json:"sig"`     // base64 Ed25519 signature (64 bytes)
}

// Welcome is the daemon's handshake response. HostPub is the daemon's raw
// Ed25519 identity key: the client verifies Sig with it AND checks its
// SSH-wire SHA256 fingerprint against the value pinned at pairing time —
// that chain is what makes the relay un-MITM-able.
type Welcome struct {
	V       int    `json:"v"`
	EphPub  string `json:"eph_pub"`
	HostPub string `json:"host_pub"`
	Sig     string `json:"sig"`
	Error   string `json:"error,omitempty"`
}

// Control is the sealed control envelope (both directions; fields by op).
//
// Since the persistent-instance rework, ops are:
//
//	client → daemon: spawn, attach{agent_id}, detach, list, kill[{agent_id}],
//	                 credit{bytes}, listdir{path}, readfile{path}, ping,
//	                 setstate{key,data}, getstate{key}
//	daemon → client: attached{agent_id,running,turn_active,acp_session_id},
//	                 detached, attachFailed{error}, agents{agents},
//	                 turnDone{agent_id,line=stopReason}, exit{code,error},
//	                 stderr{line}, dirents{path,entries},
//	                 filedata{path,data,more?|error} (large files arrive as
//	                 several chunks; more=true on all but the last), pong,
//	                 statedata{key,data}, statechanged{key}
//
// The state kv (setstate/getstate) is the workspace-structure store: the
// session ⊃ window ⊃ pane tree lives with the daemon (the tmux-server
// analogue), so an app restart or another paired device reads the same
// shape. Values are opaque base64 blobs, persisted to disk; a write fans
// out to every OTHER established stream as statechanged so live clients
// re-pull. Last write wins.
type Control struct {
	Op           string            `json:"op"`
	Cmd          string            `json:"cmd,omitempty"`
	Args         []string          `json:"args,omitempty"`
	Cwd          string            `json:"cwd,omitempty"`
	Env          map[string]string `json:"env,omitempty"`
	Bytes        int64             `json:"bytes,omitempty"`
	Path         string            `json:"path,omitempty"`
	Code         int               `json:"code,omitempty"`
	Error        string            `json:"error,omitempty"`
	Line         string            `json:"line,omitempty"`
	Entries      []DirEntry        `json:"entries,omitempty"`
	AgentID      string            `json:"agent_id,omitempty"`
	Key          string            `json:"key,omitempty"`  // statekv key
	Data         string            `json:"data,omitempty"` // base64 (readfile / readbytes / statekv)
	More         bool              `json:"more,omitempty"` // filedata: further chunks follow
	Running      bool              `json:"running,omitempty"`
	TurnActive   bool              `json:"turn_active,omitempty"`
	ACPSessionID string            `json:"acp_session_id,omitempty"`
	Agents       []InstanceInfo    `json:"agents,omitempty"`

	// Sequenced-scrollback catch-up (attach): the client sends Catchup+HaveSeq
	// (its last-processed update seq; 0 = none) and the daemon replies on
	// `attached` with HeadSeq/StartSeq (the retained log's bounds) and Replay
	// (true = the daemon streams the missing updates point-to-point before
	// joining this stream to the live broadcast). Absent Catchup = legacy
	// client → legacy behavior (no replay; client rebuilds via session/load).
	HaveSeq  uint64 `json:"have_seq,omitempty"`
	HeadSeq  uint64 `json:"head_seq,omitempty"`
	StartSeq uint64 `json:"start_seq,omitempty"`
	Catchup  bool   `json:"catchup,omitempty"`
	Replay   bool   `json:"replay,omitempty"`

	// File-preview extensions (the bento-file API): stat / listtree / readbytes.
	Size        int64       `json:"size,omitempty"`         // statdata: byte size
	IsDir       bool        `json:"is_dir,omitempty"`       // statdata: directory
	IsRegular   bool        `json:"is_regular,omitempty"`   // statdata: regular file
	Mtime       int64       `json:"mtime,omitempty"`        // statdata: unix mod time
	Tree        []TreeEntry `json:"tree,omitempty"`         // treedata: bounded listing
	MaxDepth    int         `json:"max_depth,omitempty"`    // listtree bound
	MaxEntries  int         `json:"max_entries,omitempty"`  // listtree bound
	MaxDirs     int         `json:"max_dirs,omitempty"`     // listtree bound
	MaxChildren int         `json:"max_children,omitempty"` // listtree bound
}

// DirEntry is one row of a listdir response.
type DirEntry struct {
	Name string `json:"name"`
	Dir  bool   `json:"dir"`
}

// TreeEntry is one row of a listtree response: a path relative to the listing
// root, and whether it is a directory.
type TreeEntry struct {
	Rel string `json:"rel"`
	Dir bool   `json:"dir"`
}

func marshalControl(c Control) []byte {
	b, _ := json.Marshal(c)
	return b
}
