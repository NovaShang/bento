// Package relay implements the daemon-side WSS client and the binary frame
// codec shared with the Cloudflare Worker (relay/src/daemon-do.ts).
//
// Wire format (big-endian):
//
//	0      1                  5                     N
//	+------+------------------+---------------------+
//	| type | stream_id(uint32)| payload             |
//	+------+------------------+---------------------+
//
// Type values mirror the TS side; do not renumber without bumping both ends.
package relay

import (
	"encoding/binary"
	"errors"
)

const (
	FrameOpen    byte = 0x01
	FrameData    byte = 0x02
	FrameClose   byte = 0x03
	FrameControl byte = 0x10

	// ControlStream is reserved for daemon↔relay JSON messages (pair.open,
	// pair.attach, ping/pong). Real iOS streams start at 1.
	ControlStream uint32 = 0
)

// ErrShortFrame is returned by ParseFrame when a frame is smaller than the
// fixed 5-byte header.
var ErrShortFrame = errors.New("relay: frame shorter than header")

// Frame is the decoded form of one WSS binary message.
type Frame struct {
	Type     byte
	StreamID uint32
	Payload  []byte
}

// Encode serializes f into a single allocation.
func (f Frame) Encode() []byte {
	out := make([]byte, 5+len(f.Payload))
	out[0] = f.Type
	binary.BigEndian.PutUint32(out[1:5], f.StreamID)
	copy(out[5:], f.Payload)
	return out
}

// ParseFrame is the inverse of Frame.Encode. The returned Payload aliases
// into buf — the caller must copy if it needs to retain it past the next
// websocket Read.
func ParseFrame(buf []byte) (Frame, error) {
	if len(buf) < 5 {
		return Frame{}, ErrShortFrame
	}
	return Frame{
		Type:     buf[0],
		StreamID: binary.BigEndian.Uint32(buf[1:5]),
		Payload:  buf[5:],
	}, nil
}
