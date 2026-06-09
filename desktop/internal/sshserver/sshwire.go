package sshserver

import (
	"encoding/binary"
	"errors"
	"os"
	"sync"
)

// SSH wire format helpers for the subset of session requests we care about.
// We don't bring in a dependency for this — RFC 4254 §6.

type ptyRequest struct {
	term     string
	widthPx  uint32
	heightPx uint32

	// cols/rows/tty are touched by both the request-handling goroutine
	// (window-change) and the shell goroutine (spawnShell), so guard them.
	mu         sync.Mutex
	cols, rows uint32
	tty        *os.File // bound after pty.Start
}

func parsePTYReq(p []byte) (*ptyRequest, error) {
	term, p, ok := readString(p)
	if !ok {
		return nil, errors.New("pty-req: term")
	}
	cols, p, ok := readUint32(p)
	if !ok {
		return nil, errors.New("pty-req: cols")
	}
	rows, p, ok := readUint32(p)
	if !ok {
		return nil, errors.New("pty-req: rows")
	}
	wp, p, ok := readUint32(p)
	if !ok {
		return nil, errors.New("pty-req: widthPx")
	}
	hp, _, ok := readUint32(p)
	if !ok {
		return nil, errors.New("pty-req: heightPx")
	}
	return &ptyRequest{term: term, cols: cols, rows: rows, widthPx: wp, heightPx: hp}, nil
}

func parseWindowChange(p []byte) (cols, rows uint32, ok bool) {
	c, p, ok := readUint32(p)
	if !ok {
		return 0, 0, false
	}
	r, p, ok := readUint32(p)
	if !ok {
		return 0, 0, false
	}
	// Drop trailing pixel sizes.
	_ = p
	return c, r, true
}

func parseEnv(p []byte) (string, string, bool) {
	name, p, ok := readString(p)
	if !ok {
		return "", "", false
	}
	val, _, ok := readString(p)
	if !ok {
		return "", "", false
	}
	return name, val, true
}

func marshalExitStatus(code uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, code)
	return b
}

func readUint32(p []byte) (uint32, []byte, bool) {
	if len(p) < 4 {
		return 0, p, false
	}
	return binary.BigEndian.Uint32(p[:4]), p[4:], true
}

func readString(p []byte) (string, []byte, bool) {
	if len(p) < 4 {
		return "", p, false
	}
	n := binary.BigEndian.Uint32(p[:4])
	if uint32(len(p[4:])) < n {
		return "", p, false
	}
	return string(p[4 : 4+n]), p[4+n:], true
}
