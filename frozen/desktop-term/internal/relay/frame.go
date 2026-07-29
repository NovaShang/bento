// Package relay implements the daemon-side WSS client and the binary frame
// codec shared with the Cloudflare Worker (relay/src/daemon-do.ts).
//
// Wire format (big-endian):
//
//	0       1     2                   6                     N
//	+-------+-----+-------------------+---------------------+
//	|version| type| stream_id(uint32) | payload             |
//	+-------+-----+-------------------+---------------------+
//
// The leading version byte exists so we can evolve the protocol without
// silently corrupting traffic if old and new ends meet. Both sides MUST
// reject frames with an unknown version. Type values mirror the TS side;
// do not renumber without bumping both ends and incrementing Version.
//
// Evolution rules (full policy: docs/relay-protocol.md):
//   - New frame types and new control-JSON message types are NON-breaking:
//     both ends ignore unknowns. Prefer this over version bumps.
//   - Bump Version only for header-layout changes. The relay deploys first
//     and must keep parsing every version the daemon fleet still speaks —
//     daemons announce theirs via the proto= query param at connect.
//   - This layer has NO flow control by design; the in-flight bound comes
//     from the SSH windows of the payload. Streams must only carry
//     self-flow-controlled protocols.
package relay

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	// Version is the current wire version. Bump (and add a parser branch) for
	// any breaking change.
	Version byte = 1

	FrameOpen    byte = 0x01
	FrameData    byte = 0x02
	FrameClose   byte = 0x03
	FrameControl byte = 0x10

	// ControlStream is reserved for daemon↔relay JSON messages (pair.open,
	// pair.attach, ping/pong). Real iOS streams start at 1.
	ControlStream uint32 = 0

	// headerLen is the fixed prefix size: 1 (version) + 1 (type) + 4 (stream id).
	headerLen = 6
)

// ErrShortFrame is returned by ParseFrame when a frame is smaller than the
// fixed header.
var ErrShortFrame = errors.New("relay: frame shorter than header")

// ErrVersionMismatch is returned by ParseFrame when the version byte is not
// ours. Unlike a short frame this is deterministic deployment skew — every
// subsequent frame will fail the same way — so callers should treat it as
// fatal for the session rather than skip the frame.
var ErrVersionMismatch = errors.New("relay: unsupported frame version")

// Frame is the decoded form of one WSS binary message.
type Frame struct {
	Type     byte
	StreamID uint32
	Payload  []byte
}

// Encode serializes f into a single allocation using the current Version.
func (f Frame) Encode() []byte {
	out := make([]byte, headerLen+len(f.Payload))
	out[0] = Version
	out[1] = f.Type
	binary.BigEndian.PutUint32(out[2:6], f.StreamID)
	copy(out[6:], f.Payload)
	return out
}

// fillHeader writes the frame header into buf's first headerLen bytes using
// the current Version and returns buf. The caller must have reserved the
// header space up front (len(buf) >= headerLen); this lets the output hot
// path build header+payload in one buffer without re-copying the payload.
func fillHeader(buf []byte, typ byte, streamID uint32) []byte {
	buf[0] = Version
	buf[1] = typ
	binary.BigEndian.PutUint32(buf[2:6], streamID)
	return buf
}

// ParseFrame is the inverse of Frame.Encode. The returned Payload aliases
// into buf — the caller must copy if it needs to retain it past the next
// websocket Read.
func ParseFrame(buf []byte) (Frame, error) {
	if len(buf) < headerLen {
		return Frame{}, ErrShortFrame
	}
	if buf[0] != Version {
		return Frame{}, fmt.Errorf("%w: 0x%02x (want 0x%02x)", ErrVersionMismatch, buf[0], Version)
	}
	return Frame{
		Type:     buf[1],
		StreamID: binary.BigEndian.Uint32(buf[2:6]),
		Payload:  buf[6:],
	}, nil
}
