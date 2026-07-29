package acphost

import (
	"encoding/json"
	"errors"
	"time"
)

// Restoring a respawned agent.
//
// An ACP agent process holds the conversation in memory; a new process holds
// nothing until something sends it `session/load`. Until now that something
// was always a CLIENT, which made a private need of the agent's into a client
// concern with two bad consequences: the load's replay re-streamed the whole
// conversation at whoever happened to attach first (the durable log had
// already given them the same history), and until someone attached, the agent
// sat there unable to answer a prompt.
//
// The daemon spawned the process, so the daemon restores it. Clients then
// find `initialize` and `session/load` already answered from cache and never
// touch the agent for history at all.
//
// This is the first place the daemon speaks ACP on its own behalf rather than
// relaying someone else's bytes — the direction the whole conversation layer
// is heading.

const (
	// restoreTimeout bounds one internal request. A load of a long
	// conversation is the slow one; past this we give up and leave the old
	// behavior (a client's own load) as the fallback rather than wedging.
	restoreTimeout = 90 * time.Second
)

var errAgentGone = errors.New("agent exited")

// clientCapabilitiesJSON must match what the app advertises
// (AgentSessionViewModel.clientCapabilities). An agent is initialized once
// per process, so whatever the daemon sends here is what every client gets
// back from the cache — a mismatch would change agent behavior behind their
// backs.
var clientCapabilitiesJSON = json.RawMessage(
	`{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false,` +
		`"elicitation":{"form":{}}}`)

// restoreConversation gives a freshly spawned process its conversation back.
// Runs on its own goroutine; client requests for initialize / session/load
// wait on `restored` so they read the cache instead of racing the agent.
func (inst *agentInstance) restoreConversation(sessionID, cwd string) {
	defer close(inst.restored)

	if _, err := inst.internalRequest("initialize", map[string]any{
		"protocolVersion":    1,
		"clientCapabilities": clientCapabilitiesJSON,
	}); err != nil {
		inst.updates.log("acp restore: initialize failed", "conversation", sessionID, "err", err)
		return
	}
	if _, err := inst.internalRequest("session/load", map[string]any{
		"sessionId": sessionID,
		"cwd":       cwd,
	}); err != nil {
		inst.updates.log("acp restore: session/load failed", "conversation", sessionID, "err", err)
	}
}

// internalRequest sends one JSON-RPC request the daemon issued for itself and
// waits for its response. The reply is consumed here, never forwarded: no
// client asked for it.
func (inst *agentInstance) internalRequest(method string, params any) (json.RawMessage, error) {
	done := make(chan json.RawMessage, 1)

	inst.mu.Lock()
	if inst.exited {
		inst.mu.Unlock()
		return nil, errAgentGone
	}
	inst.nextAgentID++
	agentID, _ := json.Marshal(inst.nextAgentID)
	key := idKey(agentID)
	req := clientReq{method: method, internal: done}
	if method == "session/load" {
		// Same rule as a client's load: a replay onto a non-empty log
		// re-transmits history the log already holds, so it is neither logged
		// nor delivered. With no origin stream there is nobody to deliver it
		// to either — the point of doing this here.
		if inst.updates.head() == 0 {
			req.logsLoad = true
		} else {
			inst.loadUnlogged++
		}
	}
	inst.idMap[key] = req
	inst.mu.Unlock()

	line, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      json.RawMessage(agentID),
		"method":  method,
		"params":  params,
	})
	if err != nil {
		inst.abandonInternal(key)
		return nil, err
	}
	inst.writeStdin(append(line, '\n'))

	select {
	case resp := <-done:
		return resp, nil
	case <-time.After(restoreTimeout):
		inst.abandonInternal(key)
		return nil, errors.New(method + ": timed out")
	}
}

// abandonInternal drops a request that will never be answered. Leaving it
// would keep `loadUnlogged` raised, which silently swallows every later
// notification.
func (inst *agentInstance) abandonInternal(key string) {
	inst.mu.Lock()
	defer inst.mu.Unlock()
	req, ok := inst.idMap[key]
	if !ok {
		return
	}
	delete(inst.idMap, key)
	if req.method == "session/load" && !req.logsLoad && inst.loadUnlogged > 0 {
		inst.loadUnlogged--
	}
}

// awaitRestore blocks until a restore in flight has finished, so a client's
// initialize / session/load is answered from the cache the restore fills
// rather than reaching the agent a second time. Returns immediately when no
// restore is running.
func (inst *agentInstance) awaitRestore() {
	inst.mu.Lock()
	ch := inst.restored
	inst.mu.Unlock()
	if ch == nil {
		return
	}
	select {
	case <-ch:
	case <-time.After(restoreTimeout):
	}
}
