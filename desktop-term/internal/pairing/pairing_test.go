package pairing

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"io"
	"log/slog"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/novashang/bento/desktop/internal/sshserver"
	"golang.org/x/crypto/ssh"
)

type fakeRelay struct {
	sent       []map[string]any
	on         func(map[string]any)
	reconnects []string
}

func (f *fakeRelay) ForceReconnect(reason string) {
	f.reconnects = append(f.reconnects, reason)
}

func (f *fakeRelay) SendControl(msg any) error {
	m := msg.(map[string]any)
	f.sent = append(f.sent, m)
	if f.on != nil {
		f.on(m)
	}
	return nil
}

func TestBeginThenAttach(t *testing.T) {
	dir := t.TempDir()
	keys, err := sshserver.OpenAuthorizedKeys(filepath.Join(dir, "authorized_keys"))
	if err != nil {
		t.Fatal(err)
	}
	relay := &fakeRelay{}
	m := NewManager(slog.New(slog.NewTextHandler(io.Discard, nil)), relay, keys, "SHA256:test-fp")

	// Simulate relay responding to pair.open after we call Begin.
	relay.on = func(msg map[string]any) {
		if msg["type"] == "pair.open" {
			go m.OnControl(map[string]any{
				"type":    "pair.opened",
				"code":    "123456",
				"ttl_sec": float64(60),
			})
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	resp, err := m.Begin(ctx, 0)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	if resp.Code != "123456" || resp.TTLSec != 60 {
		t.Fatalf("got %+v", resp)
	}

	// Now simulate iOS attaching with a fresh pubkey.
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sp, _ := ssh.NewPublicKey(pub)
	pkB64 := base64.StdEncoding.EncodeToString(sp.Marshal())

	relay.sent = nil
	m.OnControl(map[string]any{
		"type":          "pair.attach",
		"request_id":    "req-abc",
		"device_pubkey": pkB64,
		"device_label":  "alice-iphone",
	})

	if len(keys.List()) != 1 {
		t.Fatalf("expected 1 paired device, got %d", len(keys.List()))
	}
	if len(relay.sent) != 1 {
		t.Fatalf("expected 1 outbound control, got %+v", relay.sent)
	}
	ack := relay.sent[0]
	if ack["type"] != "pair.ack" || ack["status"] != "ok" {
		t.Fatalf("bad ack: %+v", ack)
	}
	if ack["host_fingerprint"] != "SHA256:test-fp" {
		t.Fatalf("missing host fingerprint: %+v", ack)
	}
}

func TestSanitizeLabel(t *testing.T) {
	cases := map[string]string{
		"Nova's iPhone":            "Nova's iPhone",
		"evil\nssh-ed25519 AAAA x": "evil ssh-ed25519 AAAA x",
		"crlf\r\ninjected":         "crlf  injected",
		"a:b:c":                    "a b c",
		"  padded  ":               "padded",
		"":                         "",
	}
	for in, want := range cases {
		if got := sanitizeLabel(in); got != want {
			t.Errorf("sanitizeLabel(%q) = %q, want %q", in, got, want)
		}
	}
}

// A label containing a newline + valid key line must not smuggle a second
// authorized key into the file (stealth persistence surviving revocation).
func TestAttachSanitizesMaliciousLabel(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "authorized_keys")
	keys, err := sshserver.OpenAuthorizedKeys(path)
	if err != nil {
		t.Fatal(err)
	}
	relay := &fakeRelay{}
	m := NewManager(slog.New(slog.NewTextHandler(io.Discard, nil)), relay, keys, "SHA256:test-fp")

	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sp, _ := ssh.NewPublicKey(pub)
	pkB64 := base64.StdEncoding.EncodeToString(sp.Marshal())

	evilPub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	evilSP, _ := ssh.NewPublicKey(evilPub)
	evilLine := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(evilSP)))

	m.OnControl(map[string]any{
		"type":          "pair.attach",
		"request_id":    "req-evil",
		"device_pubkey": pkB64,
		"device_label":  "evil\n" + evilLine + "\n#",
	})

	if got := keys.List(); len(got) != 1 {
		t.Fatalf("expected 1 paired device, got %d", len(got))
	} else if strings.ContainsAny(got[0].Label, "\r\n:") {
		t.Fatalf("label not sanitized: %q", got[0].Label)
	}

	// Re-open the file from disk: the injected key must not parse as a
	// second entry, and the paired device must round-trip.
	reopened, err := sshserver.OpenAuthorizedKeys(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := reopened.List(); len(got) != 1 {
		t.Fatalf("injection succeeded: %d keys on disk", len(got))
	}
}
