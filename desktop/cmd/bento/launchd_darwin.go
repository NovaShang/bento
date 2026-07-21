//go:build darwin

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/novashang/bento/desktop/internal/state"
)

// On macOS the daemon runs as a launchd LaunchAgent: it survives logout/
// login and launchd restarts it if it crashes (KeepAlive). `bento tunnel
// start` installs or refreshes the agent; `bento tunnel stop` boots it out
// and removes the plist, so a stopped daemon stays stopped across reboots.
const launchdLabel = "com.novashang.bento.acp.daemon"

func launchdPlistPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", launchdLabel+".plist"), nil
}

func launchdDomain() string { return fmt.Sprintf("gui/%d", os.Getuid()) }

// launchdJobLoaded reports whether launchd currently knows the job. A
// daemon that is running while this is false was started outside launchd
// (an older CLI, or `bento-daemon start` by hand).
func launchdJobLoaded() bool {
	return exec.Command("launchctl", "print", launchdDomain()+"/"+launchdLabel).Run() == nil
}

// startBackground writes the LaunchAgent plist pointing at exe and
// bootstraps it, replacing whatever definition launchd had under the label
// (e.g. an older binary path after an upgrade).
func startBackground(exe string) error {
	logPath, err := state.LogPath()
	if err != nil {
		return err
	}
	plist, err := launchdPlistPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(plist), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(plist, []byte(launchdPlist(exe, logPath)), 0o644); err != nil {
		return err
	}
	_ = exec.Command("launchctl", "bootout", launchdDomain()+"/"+launchdLabel).Run()
	if out, err := exec.Command("launchctl", "bootstrap", launchdDomain(), plist).CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl bootstrap: %v: %s", err, strings.TrimSpace(string(out)))
	}
	for i := 0; i < 20; i++ {
		time.Sleep(100 * time.Millisecond)
		if isDaemonRunning() {
			fmt.Printf("bento-daemon started (launchd %s, log=%s)\n", launchdLabel, logPath)
			return nil
		}
	}
	return errors.New("daemon did not become ready; check " + logPath)
}

// stopBackground boots the job out of launchd (SIGTERM, no KeepAlive
// restart) and deletes the plist. Returns whether a launchd job existed;
// the caller handles daemons running outside launchd.
func stopBackground() (bool, error) {
	plist, err := launchdPlistPath()
	if err != nil {
		return false, err
	}
	had := launchdJobLoaded()
	if had {
		if out, err := exec.Command("launchctl", "bootout", launchdDomain()+"/"+launchdLabel).CombinedOutput(); err != nil {
			return true, fmt.Errorf("launchctl bootout: %v: %s", err, strings.TrimSpace(string(out)))
		}
	}
	if err := os.Remove(plist); err != nil && !os.IsNotExist(err) {
		return had, err
	}
	return had, nil
}

func launchdPlist(exe, logPath string) string {
	env := ""
	// A daemon installed under $BENTO_HOME (e2e, side-by-side dev) must
	// keep reading that home once launchd owns it — launchd starts jobs
	// with a minimal environment.
	if home := os.Getenv("BENTO_HOME"); home != "" {
		env = fmt.Sprintf(`
  <key>EnvironmentVariables</key>
  <dict>
    <key>BENTO_HOME</key>
    <string>%s</string>
  </dict>`, xmlEscape(home))
	}
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>%s
  <key>StandardOutPath</key>
  <string>%s</string>
  <key>StandardErrorPath</key>
  <string>%s</string>
</dict>
</plist>
`, launchdLabel, xmlEscape(exe), env, xmlEscape(logPath), xmlEscape(logPath))
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}
