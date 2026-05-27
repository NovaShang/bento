package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/novashang/bento/desktop/internal/ipc"
	"github.com/novashang/bento/desktop/internal/pairing"
	"github.com/novashang/bento/desktop/internal/relay"
	"github.com/novashang/bento/desktop/internal/rpc"
	"github.com/novashang/bento/desktop/internal/sshserver"
	"github.com/novashang/bento/desktop/internal/state"
)

// daemon is the long-lived process: relay client + IPC server + pidfile +
// embedded SSH server + pairing manager.
type daemon struct {
	startedAt time.Time
	log       *slog.Logger
	cfg       state.Config

	relay     *relay.Client
	control   *controlHub
	authKeys  *sshserver.AuthorizedKeys
	hostKeyFP string
	pair      *pairing.Manager
}

func runDaemon(ctx context.Context, relayOverride string) error {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	cfg, err := state.LoadConfig()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	if relayOverride != "" {
		cfg.RelayURL = relayOverride
	}
	if cfg.RelayURL == "" {
		return errors.New("relay URL not set; pass --relay or write ~/.bento/config.json")
	}
	if cfg.DaemonID == "" {
		cfg.DaemonID = uuid.NewString()
	}
	if err := state.SaveConfig(cfg); err != nil {
		return fmt.Errorf("save config: %w", err)
	}

	if err := writePidfile(); err != nil {
		return err
	}
	defer removePidfile()

	// SSH host key + authorized devices.
	hostKeyPath, _ := state.HostKeyPath()
	signer, err := sshserver.LoadOrCreateHostKey(hostKeyPath)
	if err != nil {
		return fmt.Errorf("host key: %w", err)
	}
	authKeysPath, _ := state.AuthorizedKeysPath()
	authKeys, err := sshserver.OpenAuthorizedKeys(authKeysPath)
	if err != nil {
		return fmt.Errorf("authorized_keys: %w", err)
	}

	d := &daemon{
		startedAt: time.Now(),
		log:       logger,
		cfg:       cfg,
		control:   newControlHub(logger),
		authKeys:  authKeys,
		hostKeyFP: sshserver.Fingerprint(signer),
	}

	sshd := sshserver.New(sshserver.Options{
		Log:        logger,
		Keys:       authKeys,
		HostSigner: signer,
	})
	d.relay = relay.New(relay.Options{
		BaseURL:  cfg.RelayURL,
		DaemonID: cfg.DaemonID,
		Logger:   logger,
	}, sshd, d.control)
	sshd.RebindRelay(d.relay)

	d.pair = pairing.NewManager(logger, d.relay, authKeys, d.hostKeyFP)
	d.control.attach(d.pair)

	srv := ipc.New(d, logger)

	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer cancel()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		d.relay.Run(ctx)
	}()
	go func() {
		defer wg.Done()
		if err := srv.Listen(ctx); err != nil && !errors.Is(err, context.Canceled) {
			d.log.Error("ipc server stopped", "err", err)
		}
	}()

	logger.Info("bento-daemon started",
		"version", version,
		"daemon_id", cfg.DaemonID,
		"relay", cfg.RelayURL)

	<-ctx.Done()
	logger.Info("shutting down")
	_ = srv.Close()
	wg.Wait()
	return nil
}

// ---- Daemon interface for ipc.Server ----

func (d *daemon) StatusSnapshot() rpc.StatusResp {
	return rpc.StatusResp{
		Version:       version,
		PID:           os.Getpid(),
		UptimeSec:     int64(time.Since(d.startedAt).Seconds()),
		SSHPort:       d.cfg.SSHPort,
		RelayURL:      d.cfg.RelayURL,
		RelayConn:     d.relay.Connected(),
		DaemonID:      d.cfg.DaemonID,
		PairedDevices: len(d.authKeys.List()),
	}
}

// BeginPairing / CancelPairing delegate to the pairing manager.
func (d *daemon) BeginPairing(ctx context.Context, ttl time.Duration) (rpc.PairBeginResp, error) {
	return d.pair.Begin(ctx, ttl)
}
func (d *daemon) CancelPairing(ctx context.Context) error { return d.pair.Cancel(ctx) }

func (d *daemon) ListDevices() []rpc.DeviceSummary {
	keys := d.authKeys.List()
	out := make([]rpc.DeviceSummary, 0, len(keys))
	for _, k := range keys {
		out = append(out, rpc.DeviceSummary{
			DeviceID:    k.DeviceID,
			Label:       k.Label,
			PairedAt:    k.PairedAt,
			KeyFingerSP: k.Fingerprint(),
		})
	}
	return out
}

func (d *daemon) RevokeDevice(id string) error {
	found, err := d.authKeys.Revoke(id)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("device %s not paired", id)
	}
	return nil
}

// ---- control hub ----

// controlHub receives JSON control frames from the relay and fans them out
// to subsystems that want them (pairing manager today; more in future stages).
type controlHub struct {
	log   *slog.Logger
	mu    sync.Mutex
	pair  *pairing.Manager
}

func newControlHub(log *slog.Logger) *controlHub { return &controlHub{log: log} }

func (h *controlHub) attach(p *pairing.Manager) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.pair = p
}

func (h *controlHub) OnControl(msg map[string]any) {
	t, _ := msg["type"].(string)
	if t != "pong" { // pong is noisy; the rest is interesting
		h.log.Info("relay control", "msg", msg)
	}
	h.mu.Lock()
	p := h.pair
	h.mu.Unlock()
	if p != nil {
		p.OnControl(msg)
	}
}

// ---- pidfile ----

func writePidfile() error {
	p, err := state.PidPath()
	if err != nil {
		return err
	}
	return os.WriteFile(p, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o600)
}

func removePidfile() {
	if p, err := state.PidPath(); err == nil {
		_ = os.Remove(p)
	}
}
