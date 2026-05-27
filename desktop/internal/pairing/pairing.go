// Package pairing handles the 6-digit, one-shot device pairing flow.
//
// Roles:
//   - Operator (Mac App / `bento pair` CLI) calls Begin() → the daemon asks
//     the relay to mint a code; we return it for display.
//   - iOS POSTs the code + its Ed25519 pubkey to relay /v1/pair. The relay
//     forwards a "pair.attach" control frame to the daemon. HandleAttach()
//     installs the key and ACKs the relay with the host fingerprint, which
//     the relay returns to the still-waiting iOS HTTP request.
//
// At most one pair flow is open at a time per daemon.
package pairing

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/novashang/bento/desktop/internal/rpc"
	"github.com/novashang/bento/desktop/internal/sshserver"
	"golang.org/x/crypto/ssh"
)

// RelayPort is the subset of relay.Client we need: just sending JSON control
// frames. Defined as an interface so tests can swap it out.
type RelayPort interface {
	SendControl(msg any) error
}

// Manager is the daemon-side pairing controller.
type Manager struct {
	log        *slog.Logger
	relay      RelayPort
	keys       *sshserver.AuthorizedKeys
	hostFP     string

	mu       sync.Mutex
	openWait chan openedResult // non-nil while a Begin call is in-flight
}

type openedResult struct {
	code   string
	ttl    int
	err    error
}

// NewManager constructs a Manager. RelayPort is the live relay.Client.
func NewManager(log *slog.Logger, relay RelayPort, keys *sshserver.AuthorizedKeys, hostFP string) *Manager {
	return &Manager{log: log, relay: relay, keys: keys, hostFP: hostFP}
}

// Begin asks the relay to open a 60s pairing window and returns the code
// for display. Cancels any prior pending Begin from this daemon.
func (m *Manager) Begin(ctx context.Context, ttl time.Duration) (rpc.PairBeginResp, error) {
	if ttl <= 0 {
		ttl = 60 * time.Second
	}
	ch := make(chan openedResult, 1)
	m.mu.Lock()
	// Replace any pending begin (idempotent if user clicked twice).
	m.openWait = ch
	m.mu.Unlock()

	if err := m.relay.SendControl(map[string]any{
		"type":    "pair.open",
		"ttl_sec": int(ttl.Seconds()),
	}); err != nil {
		m.mu.Lock()
		if m.openWait == ch {
			m.openWait = nil
		}
		m.mu.Unlock()
		return rpc.PairBeginResp{}, fmt.Errorf("relay: %w", err)
	}

	select {
	case <-ctx.Done():
		m.cancelOpenWait(ch)
		return rpc.PairBeginResp{}, ctx.Err()
	case <-time.After(10 * time.Second):
		m.cancelOpenWait(ch)
		return rpc.PairBeginResp{}, errors.New("relay did not respond to pair.open within 10s")
	case r := <-ch:
		if r.err != nil {
			return rpc.PairBeginResp{}, r.err
		}
		return rpc.PairBeginResp{
			Code:      r.code,
			TTLSec:    r.ttl,
			ExpiresAt: time.Now().Add(time.Duration(r.ttl) * time.Second).Unix(),
		}, nil
	}
}

// Cancel closes any pending pairing window. Safe to call repeatedly.
func (m *Manager) Cancel(ctx context.Context) error {
	m.mu.Lock()
	ch := m.openWait
	m.openWait = nil
	m.mu.Unlock()
	if ch != nil {
		select {
		case ch <- openedResult{err: errors.New("pairing canceled")}:
		default:
		}
	}
	return m.relay.SendControl(map[string]any{"type": "pair.cancel"})
}

// OnControl routes incoming relay→daemon control messages.
func (m *Manager) OnControl(msg map[string]any) {
	switch msg["type"] {
	case "pair.opened":
		m.deliverOpened(msg)
	case "pair.attach":
		m.handleAttach(msg)
	}
}

func (m *Manager) deliverOpened(msg map[string]any) {
	code, _ := msg["code"].(string)
	ttl, _ := msg["ttl_sec"].(float64)
	m.mu.Lock()
	ch := m.openWait
	m.openWait = nil
	m.mu.Unlock()
	if ch != nil {
		ch <- openedResult{code: code, ttl: int(ttl)}
	}
}

func (m *Manager) cancelOpenWait(ch chan openedResult) {
	m.mu.Lock()
	if m.openWait == ch {
		m.openWait = nil
	}
	m.mu.Unlock()
}

// handleAttach: iOS hit /v1/pair, relay forwarded its pubkey here. We install
// it and ACK with the host fingerprint.
func (m *Manager) handleAttach(msg map[string]any) {
	reqID, _ := msg["request_id"].(string)
	pubkeyB64, _ := msg["device_pubkey"].(string)
	label, _ := msg["device_label"].(string)

	ack := func(out map[string]any) {
		out["type"] = "pair.ack"
		out["request_id"] = reqID
		if err := m.relay.SendControl(out); err != nil {
			m.log.Warn("send pair.ack", "err", err)
		}
	}

	pkBytes, err := base64.StdEncoding.DecodeString(pubkeyB64)
	if err != nil {
		ack(map[string]any{"status": "error", "error": "bad device_pubkey base64"})
		return
	}
	pk, err := ssh.ParsePublicKey(pkBytes)
	if err != nil {
		// Also try authorized-keys text form for forgiving clients.
		pk2, _, _, _, err2 := ssh.ParseAuthorizedKey([]byte(pubkeyB64))
		if err2 != nil {
			ack(map[string]any{"status": "error", "error": "parse pubkey: " + err.Error()})
			return
		}
		pk = pk2
	}

	deviceID, err := mintDeviceID()
	if err != nil {
		ack(map[string]any{"status": "error", "error": err.Error()})
		return
	}
	entry := sshserver.AuthorizedKey{
		DeviceID: deviceID,
		Label:    label,
		PubKey:   pk,
	}
	if err := m.keys.Add(entry); err != nil {
		ack(map[string]any{"status": "error", "error": "store pubkey: " + err.Error()})
		return
	}
	m.log.Info("device paired", "device_id", deviceID, "label", label, "fp", entry.Fingerprint())
	ack(map[string]any{
		"status":           "ok",
		"device_id":        deviceID,
		"host_fingerprint": m.hostFP,
		"daemon_label":     daemonLabel(),
	})
}

// daemonLabel returns a user-friendly name for this machine. iOS uses it
// as the default device label when the user didn't supply one in the
// pairing UI. On macOS we prefer ComputerName ("Nova's MacBook Pro")
// over kernel hostname; on Linux/WSL kernel hostname is fine.
func daemonLabel() string {
	if name := macComputerName(); name != "" {
		return name
	}
	name, err := os.Hostname()
	if err != nil {
		return ""
	}
	return strings.TrimSuffix(name, ".local")
}

func macComputerName() string {
	// scutil is macOS-only; on Linux this just fails and we fall back to
	// os.Hostname(). Cheap enough to attempt unconditionally.
	out, err := exec.Command("scutil", "--get", "ComputerName").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// mintDeviceID returns "dev-<8 base32 chars>".
func mintDeviceID() (string, error) {
	b := make([]byte, 5)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	const alphabet = "23456789abcdefghjkmnpqrstuvwxyz"
	out := make([]byte, 8)
	for i := range out {
		out[i] = alphabet[b[i%len(b)]%byte(len(alphabet))]
	}
	return "dev-" + string(out), nil
}
