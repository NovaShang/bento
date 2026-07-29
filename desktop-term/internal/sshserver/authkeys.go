package sshserver

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

// AuthorizedKey is one paired iOS device's entry.
//
// File format (OpenSSH authorized_keys with an optional comment we own):
//
//	<keytype> <base64> bento-device:<device_id>:<label>:<paired_unix>
type AuthorizedKey struct {
	DeviceID string
	Label    string
	PairedAt int64
	PubKey   ssh.PublicKey
	Marshal  []byte // ssh.MarshalAuthorizedKey(PubKey) (rendered form)
}

// Fingerprint returns the SHA256 fingerprint of this device's key.
func (a AuthorizedKey) Fingerprint() string { return ssh.FingerprintSHA256(a.PubKey) }

// AuthorizedKeys is the persistent paired-device set.
type AuthorizedKeys struct {
	path string
	mu   sync.RWMutex
	keys []AuthorizedKey
}

// OpenAuthorizedKeys loads from disk; missing file is fine.
func OpenAuthorizedKeys(path string) (*AuthorizedKeys, error) {
	a := &AuthorizedKeys{path: path}
	if err := a.reload(); err != nil {
		return nil, err
	}
	return a, nil
}

func (a *AuthorizedKeys) reload() error {
	b, err := os.ReadFile(a.path)
	if errors.Is(err, fs.ErrNotExist) {
		a.keys = nil
		return nil
	}
	if err != nil {
		return err
	}
	var ks []AuthorizedKey
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		pk, comment, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
		if err != nil {
			continue
		}
		dev := parseComment(comment)
		dev.PubKey = pk
		dev.Marshal = bytes.TrimRight(ssh.MarshalAuthorizedKey(pk), "\n")
		ks = append(ks, dev)
	}
	a.mu.Lock()
	a.keys = ks
	a.mu.Unlock()
	return sc.Err()
}

func parseComment(c string) AuthorizedKey {
	// "bento-device:<id>:<label>:<pairedUnix>"
	out := AuthorizedKey{}
	if !strings.HasPrefix(c, "bento-device:") {
		return out
	}
	parts := strings.SplitN(strings.TrimPrefix(c, "bento-device:"), ":", 3)
	if len(parts) >= 1 {
		out.DeviceID = parts[0]
	}
	if len(parts) >= 2 {
		out.Label = parts[1]
	}
	if len(parts) >= 3 {
		var ts int64
		fmt.Sscan(parts[2], &ts)
		out.PairedAt = ts
	}
	return out
}

func renderComment(a AuthorizedKey) string {
	return fmt.Sprintf("bento-device:%s:%s:%d", a.DeviceID, a.Label, a.PairedAt)
}

// Add appends a key. Caller supplies DeviceID + Label.
func (a *AuthorizedKeys) Add(k AuthorizedKey) error {
	if k.PairedAt == 0 {
		k.PairedAt = time.Now().Unix()
	}
	k.Marshal = bytes.TrimRight(ssh.MarshalAuthorizedKey(k.PubKey), "\n")
	a.mu.Lock()
	a.keys = append(a.keys, k)
	a.mu.Unlock()
	return a.save()
}

// Revoke removes by DeviceID. Returns false if not found.
func (a *AuthorizedKeys) Revoke(deviceID string) (bool, error) {
	a.mu.Lock()
	found := false
	out := a.keys[:0]
	for _, k := range a.keys {
		if k.DeviceID == deviceID {
			found = true
			continue
		}
		out = append(out, k)
	}
	a.keys = out
	a.mu.Unlock()
	if !found {
		return false, nil
	}
	return true, a.save()
}

// List snapshots the current set.
func (a *AuthorizedKeys) List() []AuthorizedKey {
	a.mu.RLock()
	defer a.mu.RUnlock()
	out := make([]AuthorizedKey, len(a.keys))
	copy(out, a.keys)
	return out
}

// Lookup returns the entry whose public key bytes match the offered key,
// or nil if no match.
func (a *AuthorizedKeys) Lookup(offered ssh.PublicKey) *AuthorizedKey {
	want := offered.Marshal()
	a.mu.RLock()
	defer a.mu.RUnlock()
	for i := range a.keys {
		if bytes.Equal(want, a.keys[i].PubKey.Marshal()) {
			// Return a copy, not &a.keys[i]: Revoke compacts the slice in
			// place, so an interior pointer could observe a different
			// device's entry after an unlocked mutation.
			k := a.keys[i]
			return &k
		}
	}
	return nil
}

func (a *AuthorizedKeys) save() error {
	var buf bytes.Buffer
	a.mu.RLock()
	for _, k := range a.keys {
		buf.Write(k.Marshal)
		buf.WriteByte(' ')
		buf.WriteString(renderComment(k))
		buf.WriteByte('\n')
	}
	a.mu.RUnlock()
	tmp := a.path + ".tmp"
	if err := os.WriteFile(tmp, buf.Bytes(), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.path)
}
