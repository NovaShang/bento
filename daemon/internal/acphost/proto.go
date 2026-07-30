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
//	client → daemon: spawn[{kind,session_id,target}], attach{agent_id},
//	                 detach, list, kill[{agent_id}],
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
//
// The tmux extension (docs/tmux-host-design.md) makes that analogue
// literal. The daemon speaks to the DEFAULT tmux server — the same one the
// user's own terminal talks to (a private socket exists only behind the
// BENTO_TMUX_SOCKET env override, for tests). `spawn` with kind:"tmux" is
// an ENSURE, not a process start: the daemon brings up or adopts the ONE
// `tmux -CC` control client for the target (target "" = "local", the only
// one so far), attach-or-creates the session named by session_id ("" =
// "bento") and makes it the client's current session, mirrors EVERY
// session on the server — windows ⊃ panes each — into the statekv under
// `tmux/<target>/structure` — value base64 JSON {rev, target, session,
// structure, sizing, sessions:[{id,name,attached?,structure}…]}, rev
// monotonic per target; the exact shape is documented on
// tmuxStructureState (tmuxpane.go) — and acks
// `attached{agent_id:"tmux:<target>"}` WITHOUT binding the stream. The
// daemon writes that key itself, so it reaches every live client through
// the ordinary statechanged fan-out.
//
// Each pane is then a virtual instance named `tmux:<target>:%N` (`list`
// does not report them — the structure mirror is their directory).
// attach/detach/credit and the Catchup/HaveSeq cursor work verbatim; the
// stdio differs in shape only: bytes are raw terminal output, and every
// daemon→client stdio unit is exactly one logged entry (one seq), so a
// client keeps its cursor by counting units — raw bytes have no envelope
// to carry a `_seq` stamp. Client→daemon stdio on a tmux pane is typed
// into the pane (send-keys). `kill` deliberately ignores tmux panes —
// pane lifecycle belongs to the structure op below.
//
// Scrollback seeding: the first attach of a pane whose event log is empty
// (a fresh daemon adopting a pre-existing tmux session) seeds the log from
// `capture-pane -e -p -J -S -` BEFORE any live output is appended, so a
// catch-up attach renders the pane's history and screen instead of
// blankness. Seed entries are ORDINARY log entries — seqs start at 1, one
// entry per stdio unit, the client's unit-counting cursor covers them like
// anything else; nothing on the wire marks them as synthetic.
//
// A pane's event log is a CATCH-UP buffer, not the scrollback store. tmux is
// the scrollback authority: a client binding a surface fresh (first open,
// window switch) asks `tmuxcapture` with scrollback:true and pays one
// capture bounded by the user's `history-limit`; only a client that already
// holds a cursor (a reconnect) replays the log tail behind it.
//
// The tmux WRITE path (docs/tmux-host-design.md §协议扩展 3–4):
//
//	{"op":"structure","target":"local","verb":{"kind":…, …}}
//	    executes one client StructureVerb against the tmux server
//	    (tmuxstructure.go has the verb vocabulary and the verb→command
//	    table). target "" = "local".
//	{"op":"resize","agent_id":"tmux:local:%N","cols":C,"rows":R}
//	    resize-pane -x C -y R (one pane's geometry).
//	{"op":"viewport","target":"local","cols":C,"rows":R}
//	    this STREAM's standing viewport declaration — the session-size
//	    authority's input (docs/tmux-host-design.md 步骤 5.5, the frozen
//	    product's prd §2.5 policies rehomed in the daemon; tmuxsizing.go).
//	    Re-declaring replaces it; the stream closing revokes it (the
//	    %client-detached release). A declaration, not a command: no ack —
//	    the mirror's `sizing` block {policy, owner_device, cols, rows} is
//	    the read path, republished whenever the resolution changes. The
//	    setSizePolicy structure verb picks latest|pinned|smallest; pinned's
//	    owner is the ISSUING stream, and the daemon applies the resolved
//	    size via refresh-client -C on its control client (the only real
//	    tmux client), which replaced the fixed 200×50 declaration.
//
// Both ops ack {"op":"structureApplied","rev":N} where N is a structure-
// mirror rev whose statekv value already INCLUDES the op's effect (the
// daemon re-lists after the command and acks only once that refresh has
// been published — "read at rev≥N and you will see it"), or
// {"op":"structureFailed","error":…} for malformed verbs and everything
// tmux itself refuses. Session-scoped verbs (createSession, killSession,
// renameSession, movePane, newPane/reorderPanes/applyTiled with a session
// field) address any session on the server; killing the LAST session takes
// the tmux server down and the ack rev's mirror then shows an empty server
// (session "", no sessions) — see the verb table in tmuxstructure.go.
//
// The pty extension (docs/hybrid-workbench-design.md §3, §5 P1+P2) reuses
// the same virtual-instance machinery for daemon-hosted terminals — the
// workbench's pty pane and the terminal product's no-tmux tab. `spawn` with
// kind:"pty" STARTS a process under a real pty (cmd "" = the user's login
// shell; cols/rows set the initial size; cwd/env as for ACP spawns), binds
// the spawning stream like an ACP spawn — never an ensure: there is nothing
// to adopt — and acks `attached{agent_id:"pty:<uuid>"}`. That id then works
// on the ordinary attach/detach/credit ops under the tmux panes' wire
// invariant: stdio is raw terminal bytes, and every daemon→client stdio
// unit is exactly one logged entry (one seq), so a client keeps its
// catch-up cursor by counting units. `kill` on a pty id (or on a stream
// bound to one) really kills — the daemon owns the process and kill is its
// only lifecycle op (contrast tmux panes, whose lifecycle belongs to
// `structure`).
//
//	{"op":"resize","agent_id":"pty:<uuid>","cols":C,"rows":R}
//	    pty resize ioctl; the kernel delivers SIGWINCH and a full-screen
//	    TUI repaints for the new geometry. Acked with the shapes the tmux
//	    resize chose — structureApplied{agent_id} / structureFailed{error}
//	    — minus rev: a pty pane has no structure mirror to version, and
//	    the ioctl is synchronous, so the ack itself means "applied".
//
// Persistence: the process is daemon-hosted and survives client detach —
// that is the point. It does NOT survive the daemon: after a restart the id
// is unknown and attach refuses with attachFailed (a dead pty is not
// resumable — nothing analogous to session/load exists beneath it). For the
// same reason its scrollback is the memory tail only, never durable (the
// symmetry argument lives in ptypane.go), and `list` does not report pty
// panes — the client's own workspace structure records their ids.
//
// P3 seam (honest limitation): until the daemon-side vt grid lands, a
// re-attach at a DIFFERENT size replays raw bytes laid out for the old
// width — the usual TUI smear in the scrollback — and the client's
// follow-up resize+SIGWINCH is what corrects the current screen (the
// latest-wins size semantics P2 chose). Cross-size scrollback fidelity is
// exactly what the vt-grid stage exists to add.
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

	// requestAnswered only: which agent→client request was just answered,
	// as the agent's own JSON-RPC id (those ids are broadcast unrewritten,
	// so every viewer sees the same one).
	RequestID string `json:"request_id,omitempty"`

	// attach/spawn: the client asserting that it is already HOLDING this
	// conversation's transcript (it has one rendered, not merely delivered).
	// Only the client can know that, which is the whole point — the daemon
	// inferring it from the cursor blanked every pane on a live workspace.
	// Combined with a cursor at the log head it means "send me no history",
	// and the client's session/load is then answered from cache.
	HoldsTranscript bool `json:"holds_transcript,omitempty"`

	// spawn only: the conversation (ACP session id) this process is being
	// started for. Naming it makes the spawn an ENSURE — a live process for
	// that conversation is adopted instead of duplicated — and binds the
	// conversation's durable event log before the agent says anything.
	// Absent (fresh conversation, or an older client) = spawn unconditionally.
	// For kind:"tmux" this is the tmux SESSION NAME being ensured instead
	// ("" = "bento") — same field, same ensure semantics, different registry.
	SessionID string `json:"session_id,omitempty"`

	// spawn only: which kind of pane this stream wants. "" or "acp" is the
	// ACP agent path (every field above keeps its meaning, wire-compatible
	// with every existing client); "tmux" is the ensure described in the
	// doc comment; "pty" starts a daemon-hosted pty process (the pty
	// extension above). Unknown kinds are refused, never defaulted.
	Kind string `json:"kind,omitempty"`

	// spawn kind=tmux / structure / structureApplied|Failed: the tmux server
	// target. "" = "local"; reserved for ssh:// targets in a later step.
	Target string `json:"target,omitempty"`

	// structure only: the verb to execute (see StructureVerb). The wire form
	// mirrors the client's StructureAuthority vocabulary field for field.
	Verb *StructureVerb `json:"verb,omitempty"`

	// structureApplied only: the structure-mirror rev that includes the
	// op's effect (see the doc comment above).
	Rev uint64 `json:"rev,omitempty"`

	// resize (and spawn kind=pty, where they set the initial pty size):
	// the pane's size in cells.
	Cols int `json:"cols,omitempty"`
	Rows int `json:"rows,omitempty"`

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

	// tmuxpanesdata only: every pane on the target's tmux server with the
	// live state-detection inputs the structure mirror deliberately excludes
	// (pane_current_command flaps with every foreground process and
	// pane_title with every spinner frame — neither may mint mirror revs).
	// Clients POLL this instead, exactly as the frozen product polled
	// list-panes every detection tick (tmuxstatus.go).
	Panes []TmuxPaneStatus `json:"panes,omitempty"`

	// tmuxcapture/tmuxcapturedata: ask for the pane's whole scrollback as
	// RENDERABLE bytes (`capture-pane -e -J -S -`, \r\n line ends) instead
	// of the default plain visible screen. Echoed on the reply so a client
	// can tell the two payloads apart. This is the fresh-bind scrollback
	// source (tmuxstatus.go): tmux, not the event log, is the authority for
	// history — a capture is bounded by the user's `history-limit`, a log
	// replay grows with session lifetime.
	Scrollback bool `json:"scrollback,omitempty"`
}

// TmuxPaneStatus is one row of a tmuxpanesdata reply: the per-pane
// detection inputs (see the Panes field comment), plus the pane's live
// working directory — also a flapping reading (every cd) the mirror may
// not carry, also only meaningful fresh (file preview / directory pickers
// resolve against it at call time).
type TmuxPaneStatus struct {
	Pane    string `json:"pane"`              // "%N"
	Command string `json:"command,omitempty"` // pane_current_command
	Title   string `json:"title,omitempty"`   // pane_title
	Path    string `json:"path,omitempty"`    // pane_current_path (absolute; "" unknown)

	// The pane's INTERACTION mode — same discipline as the fields above: a
	// per-pane reading that flaps with the program (a TUI starting or
	// exiting, copy-mode entered and left) and would mint a structure rev
	// per flap, so the poller pays for it and nobody else.
	//
	// A client needs them because it sees only the output that arrives
	// AFTER it binds: a surface opened mid-program never saw the `?1049h`
	// or the mouse-enable the program sent when it started. AlternateOn
	// tells it a fullscreen TUI owns the screen (so history navigation does
	// not apply); MouseAny/MouseSGR are what let it forward the wheel and
	// clicks to the program instead of scrolling its own scrollback; InMode
	// says tmux owns the viewport (copy-mode) and the wheel belongs to it.
	AlternateOn bool `json:"alternate_on,omitempty"` // alternate_on
	MouseAny    bool `json:"mouse_any,omitempty"`    // mouse_any_flag
	MouseSGR    bool `json:"mouse_sgr,omitempty"`    // mouse_sgr_flag
	InMode      bool `json:"in_mode,omitempty"`      // pane_in_mode
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
