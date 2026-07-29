package relay

import (
	"bytes"
	"errors"
	"testing"
)

func TestFrameRoundtrip(t *testing.T) {
	cases := []Frame{
		{Type: FrameOpen, StreamID: 1, Payload: nil},
		{Type: FrameData, StreamID: 42, Payload: []byte("hello")},
		{Type: FrameControl, StreamID: 0, Payload: []byte(`{"type":"ping"}`)},
		{Type: FrameClose, StreamID: 0x01020304, Payload: []byte{0xff, 0x00}},
	}
	for _, c := range cases {
		f, err := ParseFrame(c.Encode())
		if err != nil {
			t.Fatalf("parse: %v", err)
		}
		if f.Type != c.Type || f.StreamID != c.StreamID || !bytes.Equal(f.Payload, c.Payload) {
			t.Fatalf("mismatch: got %+v want %+v", f, c)
		}
	}
}

func TestParseFrameShort(t *testing.T) {
	if _, err := ParseFrame([]byte{0x01, 0x00, 0x00}); err == nil {
		t.Fatal("expected ErrShortFrame")
	}
}

func TestParseFrameVersionMismatch(t *testing.T) {
	frame := Frame{Type: FrameData, StreamID: 7, Payload: []byte("x")}.Encode()
	frame[0] = 0x02 // future wire version
	_, err := ParseFrame(frame)
	if !errors.Is(err, ErrVersionMismatch) {
		t.Fatalf("want ErrVersionMismatch, got %v", err)
	}
}
