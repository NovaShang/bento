package sshserver

import (
	"errors"
	"io"
	"net"
	"sync"
	"time"
)

// streamConn adapts a single relay stream (binary frames) into a net.Conn so
// it can be handed to ssh.NewServerConn unmodified.
//
// Inbound bytes (from iOS) arrive via FeedFromRelay (called by the relay
// client's StreamHandler.OnOpen path) and are buffered in pipeR.
// Outbound bytes (SSH server's writes) go straight to the relay client's
// per-stream writer.
type streamConn struct {
	pipeR *io.PipeReader
	pipeW *io.PipeWriter
	out   io.Writer

	mu     sync.Mutex
	closed bool
}

func newStreamConn(out io.Writer) *streamConn {
	r, w := io.Pipe()
	return &streamConn{pipeR: r, pipeW: w, out: out}
}

// FeedFromRelay is what the relay StreamHandler calls to deliver iOS bytes.
// It blocks if the SSH server isn't reading fast enough — backpressure
// propagates correctly to the relay.
func (s *streamConn) FeedFromRelay(p []byte) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return io.ErrClosedPipe
	}
	s.mu.Unlock()
	_, err := s.pipeW.Write(p)
	return err
}

func (s *streamConn) Read(p []byte) (int, error) { return s.pipeR.Read(p) }
func (s *streamConn) Write(p []byte) (int, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return 0, io.ErrClosedPipe
	}
	s.mu.Unlock()
	return s.out.Write(p)
}

func (s *streamConn) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	s.mu.Unlock()
	_ = s.pipeW.Close()
	_ = s.pipeR.Close()
	return nil
}

// net.Conn boilerplate. SSH server uses LocalAddr/RemoteAddr only for logging.

type relayAddr struct{ tag string }

func (a relayAddr) Network() string { return "relay" }
func (a relayAddr) String() string  { return a.tag }

func (s *streamConn) LocalAddr() net.Addr              { return relayAddr{tag: "daemon"} }
func (s *streamConn) RemoteAddr() net.Addr             { return relayAddr{tag: "ios-stream"} }
func (s *streamConn) SetDeadline(time.Time) error      { return errDeadlineUnsupported }
func (s *streamConn) SetReadDeadline(time.Time) error  { return errDeadlineUnsupported }
func (s *streamConn) SetWriteDeadline(time.Time) error { return errDeadlineUnsupported }

var errDeadlineUnsupported = errors.New("sshserver: relay stream does not support deadlines")

// ensure compile-time conformance
var _ net.Conn = (*streamConn)(nil)
