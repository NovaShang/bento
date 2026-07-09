package sshserver

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/ssh"
)

// bento-file: a one-shot, read-only file stat/read subsystem for the iOS
// app's tap-to-preview feature. The client opens a session channel, requests
// the "bento-file" subsystem, writes ONE JSON request line, and reads back a
// JSON header line followed by raw file bytes; the daemon then closes the
// channel. No framing state, no multiplexing — a fetch's lifecycle can never
// touch the shell session.
//
// This grants nothing the paired device doesn't already have (the same
// channel type spawns a full login shell), and it's strictly read-only.

type fileFetchRequest struct {
	Op       string `json:"op"` // "stat" | "read"
	Path     string `json:"path"`
	Cwd      string `json:"cwd,omitempty"`
	MaxBytes int64  `json:"max_bytes,omitempty"`
}

type fileFetchHeader struct {
	OK        bool   `json:"ok"`
	Error     string `json:"error,omitempty"`
	Path      string `json:"path,omitempty"`
	Size      int64  `json:"size,omitempty"`
	IsDir     bool   `json:"is_dir,omitempty"`
	IsRegular bool   `json:"is_regular,omitempty"`
	Mtime     int64  `json:"mtime,omitempty"`
	DataLen   int64  `json:"data_len,omitempty"`
	Truncated bool   `json:"truncated,omitempty"`
}

// Hard ceiling regardless of what the client asks for.
const fileFetchMaxBytes = 32 << 20 // 32 MiB

// requestLineLimit bounds the JSON request line so a misbehaving client
// can't grow the buffered reader without bound.
const requestLineLimit = 64 << 10

func (s *Server) serveFileFetch(ch ssh.Channel) {
	defer ch.Close()

	r := bufio.NewReaderSize(io.LimitReader(ch, requestLineLimit), 16<<10)
	line, err := r.ReadBytes('\n')
	if err != nil && len(line) == 0 {
		writeFileHeader(ch, fileFetchHeader{Error: "bento-file: missing request"})
		return
	}
	var req fileFetchRequest
	if err := json.Unmarshal(line, &req); err != nil {
		writeFileHeader(ch, fileFetchHeader{Error: "bento-file: bad request: " + err.Error()})
		return
	}

	path, err := resolveFetchPath(req.Path, req.Cwd)
	if err != nil {
		writeFileHeader(ch, fileFetchHeader{Error: err.Error()})
		return
	}
	info, err := os.Stat(path) // follows symlinks
	if err != nil {
		writeFileHeader(ch, fileFetchHeader{Error: err.Error()})
		return
	}

	h := fileFetchHeader{
		OK:        true,
		Path:      path,
		Size:      info.Size(),
		IsDir:     info.IsDir(),
		IsRegular: info.Mode().IsRegular(),
		Mtime:     info.ModTime().Unix(),
	}

	if req.Op != "read" || !h.IsRegular {
		writeFileHeader(ch, h)
		return
	}

	limit := req.MaxBytes
	if limit <= 0 || limit > fileFetchMaxBytes {
		limit = fileFetchMaxBytes
	}
	f, err := os.Open(path)
	if err != nil {
		writeFileHeader(ch, fileFetchHeader{Error: err.Error()})
		return
	}
	defer f.Close()

	n := info.Size()
	if n > limit {
		n = limit
		h.Truncated = true
	}
	h.DataLen = n
	if !writeFileHeader(ch, h) {
		return
	}
	_, _ = io.Copy(ch, io.LimitReader(f, n))
}

func writeFileHeader(ch ssh.Channel, h fileFetchHeader) bool {
	b, err := json.Marshal(h)
	if err != nil {
		return false
	}
	b = append(b, '\n')
	_, err = ch.Write(b)
	return err == nil
}

// resolveFetchPath expands `~`, joins relative paths onto the pane's cwd,
// and cleans the result. The daemon runs as the login user, so `~` is just
// the user's home.
func resolveFetchPath(path, cwd string) (string, error) {
	if path == "" {
		return "", errFetch("empty path")
	}
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		path = filepath.Join(home, strings.TrimPrefix(path[1:], "/"))
	}
	if !filepath.IsAbs(path) {
		if cwd == "" || !filepath.IsAbs(cwd) {
			return "", errFetch("relative path with unknown working directory")
		}
		path = filepath.Join(cwd, path)
	}
	return filepath.Clean(path), nil
}

type errFetch string

func (e errFetch) Error() string { return string(e) }

// parseSubsystem reads the subsystem name from an SSH "subsystem" request
// payload (RFC 4254 §6.5: one string).
func parseSubsystem(p []byte) (string, bool) {
	name, _, ok := readString(p)
	return name, ok
}
