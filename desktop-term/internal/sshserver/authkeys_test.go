package sshserver

import (
	"crypto/ed25519"
	"crypto/rand"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestAuthorizedKeysRoundtrip(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "authorized_keys")

	a, err := OpenAuthorizedKeys(p)
	if err != nil {
		t.Fatal(err)
	}
	if got := len(a.List()); got != 0 {
		t.Fatalf("empty store, got %d", got)
	}

	pub := genPub(t)
	if err := a.Add(AuthorizedKey{
		DeviceID: "dev-1",
		Label:    "alice-iphone",
		PubKey:   pub,
	}); err != nil {
		t.Fatal(err)
	}
	if got := len(a.List()); got != 1 {
		t.Fatalf("after add: %d", got)
	}

	// Reload from disk: should still be there with metadata preserved.
	b, err := OpenAuthorizedKeys(p)
	if err != nil {
		t.Fatal(err)
	}
	got := b.List()
	if len(got) != 1 || got[0].DeviceID != "dev-1" || got[0].Label != "alice-iphone" {
		t.Fatalf("reload mismatch: %+v", got)
	}
	if got[0].PairedAt == 0 {
		t.Fatal("PairedAt zero")
	}

	// Lookup by offered key.
	if b.Lookup(pub) == nil {
		t.Fatal("lookup failed")
	}

	// Revoke.
	ok, err := b.Revoke("dev-1")
	if err != nil || !ok {
		t.Fatalf("revoke: ok=%v err=%v", ok, err)
	}
	if got := len(b.List()); got != 0 {
		t.Fatalf("after revoke: %d", got)
	}
}

func genPub(t *testing.T) ssh.PublicKey {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sp, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return sp
}
