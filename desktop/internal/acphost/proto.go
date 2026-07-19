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

	// MaxUnit bounds a single length-prefixed unit (sanity limit).
	MaxUnit = 1 << 20

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
//	                 filedata{path,data|error}, pong,
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
	Data         string            `json:"data,omitempty"` // base64 (readfile / statekv)
	Running      bool              `json:"running,omitempty"`
	TurnActive   bool              `json:"turn_active,omitempty"`
	ACPSessionID string            `json:"acp_session_id,omitempty"`
	Agents       []InstanceInfo    `json:"agents,omitempty"`
}

// DirEntry is one row of a listdir response.
type DirEntry struct {
	Name string `json:"name"`
	Dir  bool   `json:"dir"`
}

func marshalControl(c Control) []byte {
	b, _ := json.Marshal(c)
	return b
}
