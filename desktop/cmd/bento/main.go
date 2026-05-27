// bento is the user-facing CLI. It is intentionally tiny: its only job is to
// establish/maintain the relay connection on a host so that iOS can find it.
// tmux session and agent management are left to the user's existing tmux.
//
//   bento tunnel start  start the daemon (foreground or background)
//   bento tunnel stop   stop the daemon
//   bento tunnel status alias for `bento status`
//   bento status        show daemon + relay status
//   bento pair          open a one-shot pairing window, print the 6-digit code
//   bento devices       list paired iOS devices
//   bento devices revoke <id>  remove a paired device
//
// There is no account/login command: pairing is the only identity layer.
// Each iOS device pairs out-of-band with the 6-digit code; the daemon and
// relay never see a user identity.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/novashang/bento/desktop/internal/ipc"
	"github.com/novashang/bento/desktop/internal/state"
)

const version = "0.0.1-dev"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd, args := os.Args[1], os.Args[2:]
	switch cmd {
	case "tunnel":
		runTunnel(args)
	case "status":
		mustRun(runStatus())
	case "pair":
		mustRun(runPair())
	case "devices":
		mustRun(runDevices(args))
	case "version", "--version", "-v":
		fmt.Println("bento", version)
	case "help", "--help", "-h":
		usage()
	default:
		usage()
		os.Exit(2)
	}
}

func runTunnel(args []string) {
	if len(args) == 0 {
		fmt.Println("usage: bento tunnel {start|stop|status}")
		os.Exit(2)
	}
	switch args[0] {
	case "start":
		mustRun(tunnelStart(args[1:]))
	case "stop":
		mustRun(tunnelStop())
	case "status":
		mustRun(runStatus())
	default:
		fmt.Println("usage: bento tunnel {start|stop|status}")
		os.Exit(2)
	}
}

// tunnelStart spawns bento-daemon in the background (or foreground with --fg).
// If a daemon is already running, this is a no-op.
func tunnelStart(args []string) error {
	if isDaemonRunning() {
		fmt.Println("bento-daemon already running")
		return nil
	}
	fg := false
	for _, a := range args {
		if a == "--fg" {
			fg = true
		}
	}
	exe, err := findDaemonBinary()
	if err != nil {
		return err
	}
	if fg {
		c := exec.Command(exe, "start")
		c.Stdout, c.Stderr, c.Stdin = os.Stdout, os.Stderr, os.Stdin
		return c.Run()
	}
	logPath, _ := state.LogPath()
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	c := exec.Command(exe, "start")
	c.Stdout, c.Stderr = f, f
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := c.Start(); err != nil {
		f.Close()
		return err
	}
	// Wait briefly so we can confirm it didn't immediately crash.
	for i := 0; i < 20; i++ {
		time.Sleep(100 * time.Millisecond)
		if isDaemonRunning() {
			fmt.Printf("bento-daemon started (pid=%d, log=%s)\n", c.Process.Pid, logPath)
			return nil
		}
	}
	return errors.New("daemon did not become ready; check " + logPath)
}

func tunnelStop() error {
	pid, ok := readPid()
	if !ok {
		fmt.Println("bento-daemon not running")
		return nil
	}
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return err
	}
	for i := 0; i < 50; i++ {
		if !isDaemonRunning() {
			fmt.Println("bento-daemon stopped")
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("bento-daemon did not exit within 5s")
}

func runStatus() error {
	c, err := ipc.NewClient()
	if err != nil {
		return err
	}
	st, err := c.Status(context.Background())
	if err != nil {
		return err
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(st)
}

func runPair() error {
	c, err := ipc.NewClient()
	if err != nil {
		return err
	}
	resp, err := c.PairBegin(context.Background())
	if err != nil {
		return err
	}
	fmt.Printf("pairing code: %s  (expires in %ds)\n", resp.Code, resp.TTLSec)
	return nil
}

func runDevices(args []string) error {
	c, err := ipc.NewClient()
	if err != nil {
		return err
	}
	if len(args) >= 2 && args[0] == "revoke" {
		return c.Revoke(context.Background(), args[1])
	}
	resp, err := c.Devices(context.Background())
	if err != nil {
		return err
	}
	if len(resp.Devices) == 0 {
		fmt.Println("no paired devices")
		return nil
	}
	for _, d := range resp.Devices {
		fmt.Printf("%s  %s  paired=%s\n", d.DeviceID, d.Label, time.Unix(d.PairedAt, 0).Format(time.RFC3339))
	}
	return nil
}

// ---- helpers ----

func isDaemonRunning() bool {
	c, err := ipc.NewClient()
	if err != nil {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	_, err = c.Status(ctx)
	return err == nil
}

func readPid() (int, bool) {
	p, err := state.PidPath()
	if err != nil {
		return 0, false
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return 0, false
	}
	var pid int
	if _, err := fmt.Sscan(string(b), &pid); err != nil {
		return 0, false
	}
	return pid, pid > 0
}

func findDaemonBinary() (string, error) {
	// Adjacent to `bento` first (common in dev), then PATH.
	exe, err := os.Executable()
	if err == nil {
		guess := filepath.Join(filepath.Dir(exe), "bento-daemon")
		if _, err := os.Stat(guess); err == nil {
			return guess, nil
		}
	}
	if p, err := exec.LookPath("bento-daemon"); err == nil {
		return p, nil
	}
	return "", errors.New("bento-daemon binary not found in PATH or next to bento")
}

func mustRun(err error) {
	if err == nil {
		return
	}
	fmt.Fprintln(os.Stderr, "bento:", err)
	os.Exit(1)
}

func usage() {
	fmt.Fprintln(os.Stderr, `bento — small CLI to join this host to the Bento relay

Usage:
  bento tunnel start [--fg]       start the daemon (background by default)
  bento tunnel stop               stop the daemon
  bento status                    show daemon + relay status
  bento pair                      open a pairing window, display the code
  bento devices [revoke <id>]     list / revoke paired iOS devices
  bento version`)
}
