package relay

import "time"

// maxGracedProbes bounds how many consecutive probe failures the ping loops
// forgive while writes are still completing. With the default 30s probe
// interval this trades ≤90s of extra half-open detection latency for not
// killing every session whenever a bulk transfer saturates a slow uplink.
const maxGracedProbes = 3

// livenessGate decides whether a failed liveness probe (WS protocol ping or
// app-level ping) should force a reconnect, or be forgiven because the send
// path is demonstrably still moving bytes.
//
// Why forgive at all: probes and stream data share one TCP connection and one
// write mutex, so on a slow uplink a bulk transfer (`cat` of a big file, SFTP
// preview) can starve a probe past its timeout while the link is perfectly
// healthy. Without grace, every such transfer tears down ALL streams and the
// reconnect restarts the transfer — a self-sustaining storm.
//
// Why cap the forgiveness: on a half-open socket (NAT dropped the path, RST
// eaten) writes keep "succeeding" into the kernel buffer for a while — the
// exact failure appPingLoop exists to catch. Uncapped grace would reintroduce
// that outage, so maxGraced bounds the added detection latency to
// maxGraced × probe interval.
type livenessGate struct {
	graced    int
	maxGraced int
}

// shouldReconnect reports whether this probe failure must tear the session
// down. sinceWrite is how long ago the last WS write completed; a write
// within one probe interval is evidence the path is congested, not dead.
func (g *livenessGate) shouldReconnect(sinceWrite, probeInterval time.Duration) bool {
	if sinceWrite < probeInterval && g.graced < g.maxGraced {
		g.graced++
		return false
	}
	return true
}

// probeSucceeded resets the grace budget; only consecutive failures count.
func (g *livenessGate) probeSucceeded() { g.graced = 0 }
