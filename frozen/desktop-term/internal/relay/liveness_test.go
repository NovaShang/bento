package relay

import (
	"testing"
	"time"
)

func TestLivenessGateGracesBusyLink(t *testing.T) {
	g := livenessGate{maxGraced: 3}
	interval := 30 * time.Second

	// Writes completed 1s ago → busy, not dead. Three failures forgiven.
	for i := 1; i <= 3; i++ {
		if g.shouldReconnect(time.Second, interval) {
			t.Fatalf("probe failure %d should be graced while writes progress", i)
		}
	}
	// Fourth consecutive failure exhausts the budget even with fresh writes —
	// this is the half-open-socket backstop.
	if !g.shouldReconnect(time.Second, interval) {
		t.Fatal("grace budget must be capped")
	}
}

func TestLivenessGateIdleLinkFailsImmediately(t *testing.T) {
	g := livenessGate{maxGraced: 3}
	// No write within the probe interval → nothing to blame congestion on.
	if !g.shouldReconnect(31*time.Second, 30*time.Second) {
		t.Fatal("stale writes must not grace a probe failure")
	}
}

func TestLivenessGateSuccessResetsBudget(t *testing.T) {
	g := livenessGate{maxGraced: 1}
	interval := 30 * time.Second
	if g.shouldReconnect(time.Second, interval) {
		t.Fatal("first failure should be graced")
	}
	g.probeSucceeded()
	if g.shouldReconnect(time.Second, interval) {
		t.Fatal("budget should refill after a successful probe")
	}
}
