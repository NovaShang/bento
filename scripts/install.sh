#!/usr/bin/env sh
# install.sh — one-shot installer for the bento daemon + CLI.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NovaShang/bento/main/scripts/install.sh | sh
#
# Detects host (os, arch), pulls the matching tarball from the latest GH
# release, verifies its SHA-256, and drops bento / bento-daemon into a bin
# directory. Bundled tmux ships alongside as `bento-tmux` when available
# (the resolver in bento-daemon prefers a system tmux >= 3.2 over it).
#
# Env overrides
#   BENTO_VERSION   tag to install (default: latest release)
#   BENTO_PREFIX    install root (default: /usr/local; falls back to
#                   $HOME/.local if /usr/local/bin isn't writable)
#   BENTO_REPO      GitHub repo to pull from (default: NovaShang/bento)

set -eu

REPO="${BENTO_REPO:-NovaShang/bento}"

# ---- detect host ----------------------------------------------------------

os_raw="$(uname -s)"
arch_raw="$(uname -m)"

case "$os_raw" in
  Darwin) os="darwin" ;;
  Linux)  os="linux"  ;;
  *)
    echo "install.sh: unsupported OS '$os_raw' — only macOS and Linux are supported" >&2
    exit 1
    ;;
esac

case "$os/$arch_raw" in
  darwin/arm64)            slot="darwin-arm64"  ;;
  darwin/aarch64)          slot="darwin-arm64"  ;;
  darwin/x86_64)
    echo "install.sh: Intel Macs aren't shipped as a prebuilt binary." >&2
    echo "             Build locally: 'cd desktop && make build'." >&2
    exit 1
    ;;
  linux/x86_64|linux/amd64) slot="linux-x86_64" ;;
  linux/aarch64|linux/arm64) slot="linux-arm64" ;;
  *)
    echo "install.sh: unsupported host '$os/$arch_raw'" >&2
    exit 1
    ;;
esac

# ---- pick a writable install dir -----------------------------------------

prefix="${BENTO_PREFIX:-/usr/local}"
bindir="$prefix/bin"
if [ ! -w "$prefix" ] && [ ! -w "$(dirname "$bindir")" 2>/dev/null ]; then
  # Fall back to a user-local prefix if /usr/local needs sudo. Most distros
  # keep $HOME/.local/bin on PATH already; we still print a hint at the end.
  prefix="${HOME}/.local"
  bindir="$prefix/bin"
fi
mkdir -p "$bindir"

# ---- resolve tag ---------------------------------------------------------

tag="${BENTO_VERSION:-}"
if [ -z "$tag" ]; then
  tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
    | head -n 1)"
fi
if [ -z "$tag" ]; then
  echo "install.sh: failed to resolve latest tag from $REPO" >&2
  exit 1
fi

asset="bento-$slot.tar.gz"
url="https://github.com/$REPO/releases/download/$tag/$asset"
sha_url="$url.sha256"

# ---- download + verify ---------------------------------------------------

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t bento)"
trap 'rm -rf "$tmp"' EXIT

echo "install.sh: fetching $asset @ $tag …"
curl -fsSL "$url"     -o "$tmp/$asset"
curl -fsSL "$sha_url" -o "$tmp/$asset.sha256"

# Pick whichever checksum tool the host has.
if command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
else
  echo "install.sh: neither shasum nor sha256sum found; cannot verify" >&2
  exit 1
fi
expected="$(awk '{print $1}' < "$tmp/$asset.sha256")"
if [ "$actual" != "$expected" ]; then
  echo "install.sh: SHA-256 mismatch: got $actual, expected $expected" >&2
  exit 1
fi

# ---- extract + install ---------------------------------------------------

tar -C "$tmp" -xzf "$tmp/$asset"

install_bin() {
  src="$1"
  dest="$bindir/$(basename "$1")"
  if [ -f "$src" ]; then
    install -m 0755 "$src" "$dest"
    echo "  → $dest"
  fi
}

install_bin "$tmp/bento"
install_bin "$tmp/bento-daemon"
install_bin "$tmp/bento-tmux"

echo
echo "Installed bento $tag to $bindir."

case ":$PATH:" in
  *":$bindir:"*) ;;
  *)
    echo "Note: $bindir is not on your PATH."
    echo "      Add it with: export PATH=\"$bindir:\$PATH\""
    ;;
esac

cat <<EOF

Next steps:
  bento-daemon start              # run the daemon (foreground)
  bento pair                      # mint a 6-digit pairing code
  bento status                    # show daemon + relay state

EOF
