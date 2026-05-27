package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// StreamHandler reacts to relay-initiated streams. The daemon's SSH server
// plugs in here: on Open it spawns an SSH session and returns a sink bound
// to that stream's frames.
type StreamHandler interface {
	OnOpen(streamID uint32) (StreamSink, error)
}

// StreamSink is what the relay client gives to the SSH server: bytes flowing
// from iOS end up in Write; bytes the SSH server emits go through the
// returned io.Writer (obtained from Client.WriterFor).
type StreamSink interface {
	io.Writer
	Close() error
}

// ControlHandler reacts to daemon-targeted control frames (pair.opened,
// pair.attach, pong). The daemon's pairing manager subscribes here.
type ControlHandler interface {
	OnControl(msg map[string]any)
}

// Options configures the daemon-side WSS client.
type Options struct {
	BaseURL  string // e.g. https://relay.bento.novashang.com
	DaemonID string
	Logger   *slog.Logger
	// PingEvery is how often we send control "ping" so the relay knows we're alive.
	PingEvery time.Duration
	// MinBackoff/MaxBackoff bound the reconnect delay.
	MinBackoff time.Duration
	MaxBackoff time.Duration
}

// Client maintains a long-lived WSS to the relay. Run blocks until ctx is
// canceled, reconnecting on error with exponential backoff.
type Client struct {
	opts       Options
	streams    StreamHandler
	control    ControlHandler
	mu         sync.Mutex
	conn       *websocket.Conn
	connected  bool
	lastError  string
	writeMu    sync.Mutex
	activeSink map[uint32]StreamSink
}

// New constructs a Client. streams may be nil if the caller only needs the
// control plane; in that case incoming stream-open frames are immediately
// reflected closed.
func New(opts Options, streams StreamHandler, control ControlHandler) *Client {
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.PingEvery == 0 {
		opts.PingEvery = 30 * time.Second
	}
	if opts.MinBackoff == 0 {
		opts.MinBackoff = 1 * time.Second
	}
	if opts.MaxBackoff == 0 {
		opts.MaxBackoff = 30 * time.Second
	}
	return &Client{
		opts:       opts,
		streams:    streams,
		control:    control,
		activeSink: make(map[uint32]StreamSink),
	}
}

// Connected reports the current connection state for /v1/status.
func (c *Client) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

// LastError returns the last connect/read error, empty if currently happy.
func (c *Client) LastError() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastError
}

// Run dials and serves until ctx is canceled.
func (c *Client) Run(ctx context.Context) {
	backoff := c.opts.MinBackoff
	for ctx.Err() == nil {
		err := c.connectAndServe(ctx)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			c.opts.Logger.Warn("relay disconnected", "err", err, "retry_in", backoff.String())
			c.setError(err.Error())
		}
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return
		}
		backoff *= 2
		if backoff > c.opts.MaxBackoff {
			backoff = c.opts.MaxBackoff
		}
	}
}

func (c *Client) connectAndServe(ctx context.Context) error {
	wsURL, err := socketURL(c.opts.BaseURL, c.opts.DaemonID)
	if err != nil {
		return err
	}
	// First: register so the relay knows we exist. /register is idempotent.
	if err := c.register(ctx); err != nil {
		return fmt.Errorf("register: %w", err)
	}
	conn, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{"x-bento-daemon-id": []string{c.opts.DaemonID}},
	})
	if err != nil {
		return fmt.Errorf("dial %s: %w", wsURL, err)
	}
	// Large messages are fine; SSH packets are bounded by SSH itself but we
	// don't want to clip them at the relay layer.
	conn.SetReadLimit(8 * 1024 * 1024)

	c.setConnected(true, conn)
	defer c.setConnected(false, nil)
	defer conn.Close(websocket.StatusNormalClosure, "shutdown")

	pingCtx, cancelPing := context.WithCancel(ctx)
	defer cancelPing()
	go c.pingLoop(pingCtx)

	c.opts.Logger.Info("relay connected", "url", wsURL)

	for {
		typ, data, err := conn.Read(ctx)
		if err != nil {
			return err
		}
		if typ != websocket.MessageBinary {
			continue
		}
		fr, err := ParseFrame(data)
		if err != nil {
			c.opts.Logger.Debug("bad frame", "err", err, "len", len(data))
			continue
		}
		c.handle(fr)
	}
}

func (c *Client) handle(fr Frame) {
	switch fr.Type {
	case FrameControl:
		if fr.StreamID != ControlStream {
			return
		}
		var msg map[string]any
		if err := json.Unmarshal(fr.Payload, &msg); err != nil {
			c.opts.Logger.Debug("bad control json", "err", err)
			return
		}
		c.opts.Logger.Debug("control", "msg", msg)
		if c.control != nil {
			c.control.OnControl(msg)
		}
	case FrameOpen:
		if c.streams == nil {
			// No stream handler attached; reflect close so iOS isn't hung.
			c.sendFrame(Frame{Type: FrameClose, StreamID: fr.StreamID})
			return
		}
		sink, err := c.streams.OnOpen(fr.StreamID)
		if err != nil {
			c.opts.Logger.Warn("stream open failed", "id", fr.StreamID, "err", err)
			c.sendFrame(Frame{Type: FrameClose, StreamID: fr.StreamID})
			return
		}
		c.writeMu.Lock()
		c.activeSink[fr.StreamID] = sink
		c.writeMu.Unlock()
	case FrameData:
		c.writeMu.Lock()
		sink := c.activeSink[fr.StreamID]
		c.writeMu.Unlock()
		if sink == nil {
			return
		}
		if _, err := sink.Write(fr.Payload); err != nil {
			c.closeStream(fr.StreamID, "sink write failed")
		}
	case FrameClose:
		c.closeStream(fr.StreamID, "remote close")
	}
}

// WriterFor returns an io.Writer that the SSH server writes outbound bytes
// to; each Write becomes a FrameData on the wire.
func (c *Client) WriterFor(streamID uint32) io.Writer {
	return &streamWriter{client: c, streamID: streamID}
}

type streamWriter struct {
	client   *Client
	streamID uint32
}

func (w *streamWriter) Write(p []byte) (int, error) {
	if err := w.client.sendFrame(Frame{Type: FrameData, StreamID: w.streamID, Payload: p}); err != nil {
		return 0, err
	}
	return len(p), nil
}

// SendControl emits a daemon→relay JSON control frame (e.g. pair.open).
func (c *Client) SendControl(msg any) error {
	b, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return c.sendFrame(Frame{Type: FrameControl, StreamID: ControlStream, Payload: b})
}

func (c *Client) sendFrame(fr Frame) error {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return errors.New("relay: not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return conn.Write(ctx, websocket.MessageBinary, fr.Encode())
}

func (c *Client) closeStream(id uint32, reason string) {
	c.writeMu.Lock()
	sink := c.activeSink[id]
	delete(c.activeSink, id)
	c.writeMu.Unlock()
	if sink != nil {
		_ = sink.Close()
	}
	_ = c.sendFrame(Frame{Type: FrameClose, StreamID: id})
	c.opts.Logger.Debug("stream closed", "id", id, "reason", reason)
}

func (c *Client) pingLoop(ctx context.Context) {
	t := time.NewTicker(c.opts.PingEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = c.SendControl(map[string]any{"type": "ping", "t": time.Now().UnixMilli()})
		}
	}
}

func (c *Client) register(ctx context.Context) error {
	u, err := url.Parse(c.opts.BaseURL)
	if err != nil {
		return err
	}
	u.Path = "/v1/daemon/register"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), nil)
	if err != nil {
		return err
	}
	req.Header.Set("x-bento-daemon-id", c.opts.DaemonID)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("register status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

func (c *Client) setConnected(ok bool, conn *websocket.Conn) {
	c.mu.Lock()
	c.connected = ok
	c.conn = conn
	if ok {
		c.lastError = ""
	}
	c.mu.Unlock()
}

func (c *Client) setError(msg string) {
	c.mu.Lock()
	c.lastError = msg
	c.mu.Unlock()
}

// socketURL turns "https://host" into "wss://host/v1/daemon/socket?daemon_id=...".
func socketURL(base, daemonID string) (string, error) {
	u, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	default:
		return "", fmt.Errorf("relay base must be http(s), got %q", u.Scheme)
	}
	u.Path = "/v1/daemon/socket"
	q := u.Query()
	q.Set("daemon_id", daemonID)
	u.RawQuery = q.Encode()
	return u.String(), nil
}
