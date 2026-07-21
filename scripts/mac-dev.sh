#!/usr/bin/env bash
# mac-dev.sh — build the macOS client ("Bento ACP") and hot-swap the running GUI.
#
# The loop that lets an agent see a BentoCore/BentoMenubar change in the real
# app without a full release:  build → quit ONLY the GUI → relaunch → reattach.
#
# ── The one rule you must not break ─────────────────────────────────────────
# NEVER kill or restart bento-daemon. The daemon (launchd job
# `com.novashang.bento.acp.daemon`, PPID 1) HOSTS the ACP agent processes —
# including the very agent that may be running this script. It outlives the GUI
# on purpose. Restarting it kills every live agent conversation. This script
# only ever signals the GUI Mach-O ("…/Bento ACP.app/Contents/MacOS/Bento ACP"),
# which cannot match "bento-daemon" or the "bento" CLI. Quitting the GUI is
# safe: the daemon keeps the agents alive and the relaunched GUI reattaches.
#
# Usage:
#   scripts/mac-dev.sh                 # rebuild + relaunch from build/ (default)
#   scripts/mac-dev.sh build           # rebuild only, no relaunch
#   scripts/mac-dev.sh relaunch        # quit GUI + open the last build/ app
#   scripts/mac-dev.sh install         # rebuild + Developer-ID sign + install to /Applications
#   scripts/mac-dev.sh status          # show GUI + daemon + build state
#
# Notes:
#   • Default build is ad-hoc signed and runs from build/ — it does NOT touch
#     the /Applications install, so no Gatekeeper/TCC surprises. Because its
#     code identity differs from the installed app, first voice use may
#     re-prompt for microphone access. `install` preserves identity.
#   • The build's "Embed Go binaries" phase runs `make build` in desktop/, so
#     Go + Homebrew must be on PATH (they are added below for xcodebuild).
#   • Production/notarized builds are release.yml's job, not this script's.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

APP="build/Build/Products/Release/Bento ACP.app"
APP_ABS="$REPO/$APP"
# Matches the GUI executable for BOTH the /Applications and build/ copies, and
# nothing else (daemon is "bento-daemon", CLI is "bento").
GUI_MATCH="Bento ACP.app/Contents/MacOS/Bento ACP"
# Match the executable PATH ("/bento-daemon"), not the bare word, so prose
# mentions (a commit message, this script's own args) don't false-positive. The
# `[b]` also keeps the grep from matching its own argv. We detect via the
# process table, NOT pgrep: macOS pgrep can't read this launchd-managed signed
# binary's argv (KERN_PROCARGS2 returns empty) and false-negatives every time.
DAEMON_GREP='/[b]ento-daemon'
DEV_ID="Developer ID Application"   # substring; picks the release signing cert

log()  { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

daemon_pids() { ps -Axo pid=,command= 2>/dev/null | grep "$DAEMON_GREP" | awk '{print $1}'; }
daemon_alive() {
  daemon_pids | grep -q . \
    || launchctl list 2>/dev/null | grep -q 'novashang\.bento.*daemon'
}

assert_daemon_survived() {
  if daemon_alive; then
    log "daemon still alive (agents preserved): pid $(daemon_pids | head -1)"
  else
    warn "bento-daemon is NOT running — it should never have stopped here."
    warn "If an agent was hosted by it, that session was lost. It will relaunch"
    warn "via launchd / the app watchdog, but live conversations do not come back."
  fi
}

build() {
  command -v go >/dev/null 2>&1 || die "go not found (needed by the Embed Go binaries phase)"
  log "building Bento ACP (Release, ad-hoc, arm64) → $APP"
  # Xcode's PATH is minimal; give the postCompileScript go/make via Homebrew.
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  local logf=/tmp/bento-mac-build.log
  if ! xcodebuild -project Bento.xcodeproj \
      -scheme BentoMenubar \
      -configuration Release \
      -derivedDataPath build \
      ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
      CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
      build >"$logf" 2>&1; then
    tail -25 "$logf"
    die "build failed — full log: $logf"
  fi
  [ -d "$APP_ABS" ] || die "build reported success but $APP is missing"
  log "build ok"
}

quit_gui() {
  osascript -e 'quit app "Bento ACP"' >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 20); do
    pgrep -f "$GUI_MATCH" >/dev/null 2>&1 || break
    sleep 0.3
  done
  # Still up? Precise SIGTERM on the GUI executable only — never the daemon.
  if pgrep -f "$GUI_MATCH" >/dev/null 2>&1; then
    pkill -f "$GUI_MATCH" || true
    sleep 1
  fi
}

relaunch() {
  [ -d "$APP_ABS" ] || die "no build at $APP — run: scripts/mac-dev.sh build"
  log "quitting the running GUI (daemon untouched)…"
  quit_gui
  log "launching $APP"
  open "$APP_ABS"
  sleep 3
  local pid; pid="$(pgrep -f "build/.*$GUI_MATCH" | head -1 || true)"
  [ -n "$pid" ] && log "new GUI pid: $pid" || warn "GUI did not appear — check Console.app"
  assert_daemon_survived
}

install_to_applications() {
  build
  local dest="/Applications/Bento ACP.app"
  local id
  id="$(security find-identity -v -p codesigning 2>/dev/null | grep "$DEV_ID" | head -1 | awk '{print $2}')"
  if [ -n "$id" ]; then
    log "re-signing with $DEV_ID ($id) to preserve code identity / TCC grants"
    codesign --force --options=runtime --timestamp=none \
      --sign "$id" \
      --entitlements BentoMenubar/Resources/BentoMenubar.entitlements \
      "$APP_ABS" || warn "codesign failed — installing ad-hoc build instead"
  else
    warn "no '$DEV_ID' cert found — installing ad-hoc; macOS may reset this app's"
    warn "permissions (mic, etc.) because the code identity changed."
  fi
  log "quitting the running GUI (daemon untouched)…"
  quit_gui
  log "installing → $dest"
  rm -rf "$dest"
  ditto "$APP_ABS" "$dest"
  open "$dest"
  sleep 3
  assert_daemon_survived
}

status() {
  local g d
  g="$(pgrep -fl "$GUI_MATCH" 2>/dev/null || true)"
  echo "GUI:"; [ -n "$g" ] && echo "$g" | sed 's/^/  /' || echo "  (not running)"
  d="$(ps -Axo pid=,command= 2>/dev/null | grep "$DAEMON_GREP" || true)"
  echo "daemon:"; [ -n "$d" ] && echo "$d" | sed 's/^/  /' || echo "  (not running)"
  echo "last build:"
  # The .app dir mtime goes stale on incremental builds; the main Mach-O
  # (BentoCore links into it) is the honest "when did the code last change".
  if [ -f "$APP_ABS/Contents/MacOS/Bento ACP" ]; then
    stat -f "  %Sm  $APP" "$APP_ABS/Contents/MacOS/Bento ACP"
  else
    echo "  (none — run: scripts/mac-dev.sh build)"
  fi
}

case "${1:-rebuild}" in
  rebuild|"") build; relaunch ;;
  build)      build ;;
  relaunch)   relaunch ;;
  install)    install_to_applications ;;
  status)     status ;;
  *)          die "unknown command '$1' — see header for usage" ;;
esac
