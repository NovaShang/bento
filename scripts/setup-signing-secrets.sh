#!/usr/bin/env bash
# setup-signing-secrets.sh — push macOS code-signing / notarization
# credentials into this repo's GitHub Actions secrets.
#
# Inputs (paths can be overridden via env vars):
#   MACOS_P12_PATH    pre-exported Developer ID Application .p12
#                     (default: ~/Documents/Certificates.p12)
#   NOTARY_P8_PATH    App Store Connect API key .p8
#                     (default: ~/Downloads/AuthKey_<KEY_ID>.p8)
#
# A .p12 with an empty export password is auto-re-encrypted with a fresh
# random password before being pushed; CI needs *some* password to import
# the .p12 into its temporary keychain. The new password is set as the
# MACOS_CERT_PASSWORD secret and never echoed.

set -euo pipefail

TEAM_ID="7M23245ZBD"
NOTARY_KEY_ID="R2NW73H5TJ"
NOTARY_ISSUER_ID="0d7532d3-6b3c-4474-bd99-e99ecfffb04f"

MACOS_P12_PATH="${MACOS_P12_PATH:-${HOME}/Documents/Certificates.p12}"
NOTARY_P8_PATH="${NOTARY_P8_PATH:-${HOME}/Downloads/AuthKey_${NOTARY_KEY_ID}.p8}"

for f in "${MACOS_P12_PATH}" "${NOTARY_P8_PATH}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing $f" >&2
    exit 1
  fi
done

echo "→ checking gh auth"
gh auth status >/dev/null

stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT

# Try empty password first; if it works we re-encrypt under a random
# password (it's bad form to ship an unprotected .p12 into CI). Otherwise
# prompt for the password the user set on export.
echo "→ probing .p12 password"
if openssl pkcs12 -legacy -in "${MACOS_P12_PATH}" -nokeys -passin "pass:" -noout 2>/dev/null; then
  echo "  source .p12 has no password; re-encrypting under a fresh random one"
  P12_PASS="$(openssl rand -base64 24)"
  # Two-step re-encrypt: dump to PEM in memory, repack with new password.
  # Skips touching the disk for the PEM (process substitution keeps it
  # in a fifo).
  REPACKED="${stage}/identity.p12"
  pem="${stage}/identity.pem"
  umask 077
  openssl pkcs12 -legacy -in "${MACOS_P12_PATH}" -nodes -passin "pass:" -out "${pem}" >/dev/null
  openssl pkcs12 -legacy -export -in "${pem}" -out "${REPACKED}" -password "pass:${P12_PASS}" -name "Bento Developer ID" >/dev/null
  rm -f "${pem}"
  P12_TO_PUSH="${REPACKED}"
else
  # Allow non-interactive use: P12_PASS env var (or stdin when not a tty).
  if [ -n "${P12_PASS:-}" ]; then
    : # already set in env
  elif [ -t 0 ]; then
    printf "Enter the password you set when exporting %s: " "$(basename "${MACOS_P12_PATH}")"
    stty -echo
    read -r P12_PASS
    stty echo
    printf "\n"
  else
    read -r P12_PASS
  fi
  if [ -z "${P12_PASS}" ]; then
    echo "ERROR: empty password rejected" >&2
    exit 1
  fi
  if ! openssl pkcs12 -legacy -in "${MACOS_P12_PATH}" -nokeys -passin "pass:${P12_PASS}" -noout 2>/dev/null; then
    echo "ERROR: that password does not unlock ${MACOS_P12_PATH}" >&2
    exit 1
  fi
  P12_TO_PUSH="${MACOS_P12_PATH}"
fi

echo "→ setting GitHub Actions secrets"
base64 -i "${P12_TO_PUSH}" | gh secret set MACOS_CERT_P12_BASE64
gh secret set MACOS_CERT_PASSWORD    --body "${P12_PASS}"
gh secret set MACOS_TEAM_ID          --body "${TEAM_ID}"
gh secret set APPLE_NOTARY_KEY_ID    --body "${NOTARY_KEY_ID}"
gh secret set APPLE_NOTARY_ISSUER_ID --body "${NOTARY_ISSUER_ID}"
gh secret set APPLE_NOTARY_KEY_P8    < "${NOTARY_P8_PATH}"

# Best-effort wipe.
P12_PASS=""

echo
echo "done. Secrets in this repo:"
gh secret list | grep -E "MACOS_|APPLE_NOTARY" || true
