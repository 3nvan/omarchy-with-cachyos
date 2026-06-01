#!/usr/bin/env bash
set -euo pipefail

# Robust, idempotent script to set wireless regulatory domain.
# Usage: set-wireless-regdom.sh [CC]
# Where CC is an ISO 3166-1 alpha-2 country code (default: US)

COUNTRY="${1:-US}"

log() { printf '%s\n' "$*"; }

# If invoked under /bin/sh or another shell, re-exec under bash so we can
# rely on bash features and have consistent behavior when the file is sourced
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# If iw is not available, bail out gracefully (installer should continue).
if ! command -v iw >/dev/null 2>&1; then
  log "iw not found; cannot set regulatory domain. Install 'iw' and retry. Exiting gracefully.";
  exit 0
fi

# Ensure we run as root. Re-exec under sudo if needed.
if [ "$(id -u)" -ne 0 ]; then
  log "Re-running under sudo to set regulatory domain..."
  exec sudo bash "$0" "$@"
fi

# Try to unblock rfkill if wireless is blocked
if command -v rfkill >/dev/null 2>&1; then
  if rfkill list | grep -qi "blocked"; then
    log "RFKill indicates wireless is blocked; attempting to unblock..."
    rfkill unblock all || true
    sleep 1
  fi
fi

# Attempt to set the regulatory domain transiently
if iw reg set "$COUNTRY" >/dev/null 2>&1; then
  log "Regulatory domain set to $COUNTRY (transient)."
else
  log "iw reg set failed; attempting persistent fallback."
  # Create a persistent cfg80211 option so the kernel reads the regdomain on reload
  cat > /etc/modprobe.d/regdomain.conf <<EOF
# Persist regulatory domain for wireless (set by omarchy installer)
options cfg80211 ieee80211_regdom=$COUNTRY
EOF
  # Try to set /etc/default/crda if writable (some distros use this)
  if [ -w /etc/default ] || [ -w /etc/default/crda ]; then
    printf 'REGDOMAIN=%s\n' "$COUNTRY" > /etc/default/crda 2>/dev/null || true
  fi
  log "Wrote /etc/modprobe.d/regdomain.conf and attempted /etc/default/crda. A reboot or module reload may be required."
fi

# Print current regulatory status for debugging
iw reg get | sed -n '1,80p' || true

exit 0

