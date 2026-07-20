//go:build !darwin

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/novashang/bento/desktop/internal/state"
)

// startBackground detaches bento-daemon into its own session. No service
// manager integration outside macOS yet — a crash or reboot needs a manual
// `bento tunnel start`.
func startBackground(exe string) error {
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
	for i := 0; i < 20; i++ {
		time.Sleep(100 * time.Millisecond)
		if isDaemonRunning() {
			fmt.Printf("bento-daemon started (pid=%d, log=%s)\n", c.Process.Pid, logPath)
			return nil
		}
	}
	return errors.New("daemon did not become ready; check " + logPath)
}

func stopBackground() (bool, error) { return false, nil }

func launchdJobLoaded() bool { return false }
