package acphost

import (
	"context"
	"errors"
	"net"
	"os"
	"sync"
)

// ListenLocal serves the acphost protocol on a unix socket for same-user
// clients (the Mac app). No handshake or sealing — trust comes from the
// 0600 socket. This is what lets the Mac app's agents live in the daemon
// and survive app restarts, and what makes Mac and iPhone see the same
// session pool.
func (s *Server) ListenLocal(ctx context.Context, path string) error {
	_ = os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	_ = os.Chmod(path, 0o600)
	go func() {
		<-ctx.Done()
		_ = listener.Close()
		_ = os.Remove(path)
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go s.serveLocal(conn)
	}
}

func (s *Server) serveLocal(conn net.Conn) {
	sess := s.openPlaintext(&lockedWriter{w: conn})
	defer func() {
		_ = sess.Close()
		_ = conn.Close()
	}()
	buf := make([]byte, 64*1024)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			_, _ = sess.Write(buf[:n])
		}
		if err != nil {
			return
		}
	}
}

// lockedWriter serializes writes from the control path and the instance
// read loop onto one connection.
type lockedWriter struct {
	mu sync.Mutex
	w  net.Conn
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}
