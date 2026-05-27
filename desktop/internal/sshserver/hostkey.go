// Package sshserver is the embedded SSH server inside bento-daemon. It is
// the only place SSH bytes get decrypted on this side. Each accepted
// connection comes from a relay stream — there is no listening port.
package sshserver

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"fmt"
	"io/fs"
	"os"

	"golang.org/x/crypto/ssh"
)

// Compile-time check that HostSigner exposes the raw Ed25519 form. This
// matches relay.Ed25519HostSigner without importing the relay package
// (avoiding an import cycle).
var _ interface {
	RawPublicKey() []byte
	SignRaw([]byte) ([]byte, error)
} = HostSigner{}

// LoadOrCreateHostKey returns the daemon's Ed25519 SSH host key, generating
// and persisting one on first run. The key is the basis of the
// "fingerprint" iOS pins after pairing.
func LoadOrCreateHostKey(path string) (ssh.Signer, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return generateHostKey(path)
	}
	if err != nil {
		return nil, err
	}
	signer, err := ssh.ParsePrivateKey(b)
	if err != nil {
		return nil, fmt.Errorf("parse host key %s: %w", path, err)
	}
	return signer, nil
}

func generateHostKey(path string) (ssh.Signer, error) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	// OpenSSH-format PEM is what `ssh.ParsePrivateKey` expects to roundtrip.
	block, err := ssh.MarshalPrivateKey(priv, "bento-host-key")
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, pem.EncodeToMemory(block), 0o600); err != nil {
		return nil, err
	}
	return ssh.NewSignerFromKey(priv)
}

// Fingerprint returns the SHA256:... fingerprint of the host key's public part.
func Fingerprint(s ssh.Signer) string {
	return ssh.FingerprintSHA256(s.PublicKey())
}

// HostSigner wraps an ssh.Signer to expose the raw Ed25519 form the relay
// challenge needs.
type HostSigner struct {
	Signer ssh.Signer
}

// RawPublicKey returns the underlying 32-byte Ed25519 public key.
func (h HostSigner) RawPublicKey() []byte {
	cp, ok := h.Signer.PublicKey().(ssh.CryptoPublicKey)
	if !ok {
		return nil
	}
	ed, ok := cp.CryptoPublicKey().(ed25519.PublicKey)
	if !ok {
		return nil
	}
	return []byte(ed)
}

// SignRaw produces a raw 64-byte Ed25519 signature over msg. ssh.Signer
// returns an ssh.Signature whose Blob is exactly that for Ed25519 keys.
func (h HostSigner) SignRaw(msg []byte) ([]byte, error) {
	sig, err := h.Signer.Sign(rand.Reader, msg)
	if err != nil {
		return nil, err
	}
	if sig.Format != ssh.KeyAlgoED25519 {
		return nil, errors.New("host key is not Ed25519")
	}
	return sig.Blob, nil
}
