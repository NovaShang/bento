package acphost

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

// helloSigMessage is the exact byte string the device signs.
func helloSigMessage(daemonID, deviceID string, ts int64, ephPubB64 string) []byte {
	return []byte(fmt.Sprintf("bento-acp-hello:v1:%s:%s:%d:%s", daemonID, deviceID, ts, ephPubB64))
}

// welcomeSigMessage is the exact byte string the host signs.
func welcomeSigMessage(daemonID, deviceID string, ts int64, clientEphB64, hostEphB64 string) []byte {
	return []byte(fmt.Sprintf(
		"bento-acp-welcome:v1:%s:%s:%d:%s:%s", daemonID, deviceID, ts, clientEphB64, hostEphB64))
}

// deriveKeys computes the two directional ChaCha20-Poly1305 keys.
func deriveKeys(shared []byte, daemonID, deviceID string) (c2s, s2c []byte, err error) {
	salt := []byte("bento-acp-v1:" + daemonID + ":" + deviceID)
	for _, dir := range []struct {
		info string
		out  *[]byte
	}{
		{"c2s", &c2s},
		{"s2c", &s2c},
	} {
		key := make([]byte, chacha20poly1305.KeySize)
		r := hkdf.New(sha256.New, shared, salt, []byte(dir.info))
		if _, err := io.ReadFull(r, key); err != nil {
			return nil, nil, err
		}
		*dir.out = key
	}
	return c2s, s2c, nil
}

// boxer seals/opens one direction with a counter nonce.
type boxer struct {
	aead interface {
		Seal(dst, nonce, plaintext, ad []byte) []byte
	}
	opener interface {
		Open(dst, nonce, ciphertext, ad []byte) ([]byte, error)
	}
	counter uint64
}

func newBoxer(key []byte) (*boxer, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	return &boxer{aead: aead, opener: aead}, nil
}

func (b *boxer) nonce() []byte {
	n := make([]byte, chacha20poly1305.NonceSize)
	binary.LittleEndian.PutUint64(n[4:], b.counter)
	b.counter++
	return n
}

func (b *boxer) seal(plaintext []byte) []byte {
	return b.aead.Seal(nil, b.nonce(), plaintext, nil)
}

func (b *boxer) open(ciphertext []byte) ([]byte, error) {
	return b.opener.Open(nil, b.nonce(), ciphertext, nil)
}

// handshake state helpers ----------------------------------------------------

type ephemeral struct {
	priv *ecdh.PrivateKey
}

func newEphemeral() (*ephemeral, error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return &ephemeral{priv: priv}, nil
}

func (e *ephemeral) publicB64() string {
	return base64.StdEncoding.EncodeToString(e.priv.PublicKey().Bytes())
}

func (e *ephemeral) shared(peerB64 string) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(peerB64)
	if err != nil {
		return nil, fmt.Errorf("bad ephemeral key encoding: %w", err)
	}
	peer, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return nil, fmt.Errorf("bad ephemeral key: %w", err)
	}
	return e.priv.ECDH(peer)
}

func verifyEd25519(pub ed25519.PublicKey, msg []byte, sigB64 string) error {
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return errors.New("bad signature encoding")
	}
	if !ed25519.Verify(pub, msg, sig) {
		return errors.New("signature verification failed")
	}
	return nil
}

// unitBuffer reassembles 4-byte-BE length-prefixed units from arbitrary
// chunk boundaries.
type unitBuffer struct {
	buf []byte
}

func (u *unitBuffer) append(p []byte) ([][]byte, error) {
	u.buf = append(u.buf, p...)
	var units [][]byte
	for {
		if len(u.buf) < 4 {
			return units, nil
		}
		n := binary.BigEndian.Uint32(u.buf[:4])
		if n > MaxUnit {
			return units, fmt.Errorf("unit too large: %d", n)
		}
		if len(u.buf) < 4+int(n) {
			return units, nil
		}
		unit := make([]byte, n)
		copy(unit, u.buf[4:4+n])
		u.buf = u.buf[4+int(n):]
		units = append(units, unit)
	}
}

func prefixUnit(body []byte) []byte {
	out := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(out[:4], uint32(len(body)))
	copy(out[4:], body)
	return out
}
