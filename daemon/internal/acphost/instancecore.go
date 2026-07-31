package acphost

import (
	"sync"
	"sync/atomic"
)

// instanceCore is the protocol-agnostic half of a hosted instance — the part
// every kind of pane needs no matter what its process speaks: the attached
// multi-subscriber set, the sequenced event log (memory tail + durable
// segments, see eventlog.go), catch-up replay from that log into the live
// broadcast set, and exit bookkeeping. agentInstance composes it; ptyPane
// composes the same struct without
// re-growing any of the persistence machinery.
//
// Log entries are opaque bytes with a seq. The `_seq` JSON injection that
// PRODUCES an ACP entry is ACP business and stays with agentInstance
// (injectSeq / sequenceNotification); a pty pane logs raw byte chunks.
//
// ONE mutex by design: mu guards this struct and the composing instance's
// protocol state alike. The load-bearing invariants — sequencing, the log
// append and the target snapshot in a single critical section; a replay
// joining in the same critical section that observed an empty remainder —
// span both halves, so a second lock could only reorder them.
type instanceCore struct {
	// id is what exit controls carry as AgentID — a copy of the composing
	// instance's immutable ID (see spawnInstance).
	id string

	mu sync.Mutex
	// subs is the attached-subscriber set: stream → whether it was served a
	// scrollback replay on attach (it therefore already holds the
	// transcript). agentInstance.attached is this same map under its
	// historical name — see the aliasing note in spawnInstance.
	subs map[*session]bool
	// events is the sequenced scrollback (see eventlog.go);
	// agentInstance.updates is this same object under its historical name.
	events *eventLog
	// Where conversation directories live; "" = memory-only (tests).
	logRoot string

	exited   bool
	exitCode int
	exitErr  string
	// Lock-free mirror of `exited` for the server's conversation registry,
	// which must never take mu (it is claimed from under it).
	exitedFlag atomic.Bool
}

// replayAndJoin streams the scrollback tail after `cursor` to one stream,
// then atomically joins it to the live set. The join happens in the SAME
// critical section that observed an empty remainder; sequenceNotification
// appends + snapshots targets under that lock too, so every line lands via
// exactly one channel: appended while joined → broadcast; appended before →
// picked up by the next replay batch.
//
// That guarantee covers what goes through the log. State that travels
// point-to-point does not: joinLocked runs inside that final critical
// section, right after the join, and returns the follow-up to run once mu is
// released — the composing instance's chance to hand the stream whatever
// truth the log doesn't carry (see agentInstance.replayJoinLocked).
func (c *instanceCore) replayAndJoin(s *session, cursor uint64, joinLocked func() func()) {
	const batchLines = 64
	warnedGap := false
	for {
		c.mu.Lock()
		batch := c.events.since(cursor, batchLines)
		if len(batch) == 0 {
			c.subs[s] = true
			after := joinLocked()
			c.mu.Unlock()
			after()
			return
		}
		c.mu.Unlock()

		// Flood while replaying can evict past the cursor (extreme; the cap
		// is generous). Surface the hole instead of silently skipping.
		if !warnedGap && batch[0].seq > cursor+1 {
			warnedGap = true
			s.sendControl(Control{Op: "stderr",
				Line: "[bento] scrollback overflowed during catch-up — some history is missing"})
		}
		for _, e := range batch {
			s.sendStdio(e.line)
			cursor = e.seq
		}
		if s.isClosed() {
			return
		}
	}
}

// noteExit records the instance's end and broadcasts it to every attached
// stream. The history stays on disk for the next process on this
// conversation; only this process's handle goes away.
func (c *instanceCore) noteExit(code int, errMsg string) {
	c.mu.Lock()
	c.exited = true
	c.exitedFlag.Store(true)
	c.exitCode = code
	c.exitErr = errMsg
	c.events.close()
	targets := make([]*session, 0, len(c.subs))
	for s := range c.subs {
		targets = append(targets, s)
	}
	c.mu.Unlock()
	for _, s := range targets {
		s.sendControl(Control{Op: "exit", AgentID: c.id, Code: code, Error: errMsg})
	}
}
