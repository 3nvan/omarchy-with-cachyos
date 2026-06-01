#!/usr/bin/env bash
set -euo pipefail

# Robust, idempotent script to set wireless regulatory domain with retries and
# improved logging. Usage: set-wireless-regdom.sh [CC]
# Where CC is an ISO 3166-1 alpha-2 country code (default: US)

COUNTRY="${1:-US}"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*"; }

# Treat any runtime error as non-fatal for the installer: log it and exit 0.
# This prevents the installer from failing due to transient races or environment
# differences; the script will attempt fallbacks but will never return a
# non-zero status to the caller.
trap 'rc=$?; log "set-wireless-regdom.sh: non-fatal error (exit $rc); continuing with exit 0"; exit 0' ERR
# Also ensure interrupts/terminations return success to the installer.
trap 'log "set-wireless-regdom.sh: interrupted; exiting 0"; exit 0' INT TERM

# Ensure running under bash for consistent behavior
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# Ensure we run as root. Re-exec under sudo if needed.
if [ "$(id -u)" -ne 0 ]; then
  log "Not root: re-running under sudo to set regulatory domain..."
  exec sudo bash "$0" "$@"
fi

# Give udev and modules a chance to settle (helps avoid races where cfg80211
# or other wireless modules aren't yet ready). This will block briefly until
# udev reports it has processed events.
if command -v udevadm >/dev/null 2>&1; then
  log "Waiting for udev to settle..."
  udevadm settle || true
fi

# Try to proactively load wireless helper module; some systems need this
# before `iw`/cfg80211 operations succeed.
if command -v modprobe >/dev/null 2>&1; then
  log "Attempting to load cfg80211 module (if not already loaded)"
  modprobe cfg80211 >/dev/null 2>&1 || true
fi

# Wait for `iw` to become available (up to 30s). Some installer flows install
# tools asynchronously, so this avoids a hard failure if `iw` appears shortly.
WAIT_IW=30
for i in $(seq 1 $WAIT_IW); do
  if command -v iw >/dev/null 2>&1; then
    break
  fi
  log "Waiting for 'iw' to be available... ($i/$WAIT_IW)"
  sleep 1
done

if ! command -v iw >/dev/null 2>&1; then
  log "iw not found after waiting; cannot set regulatory domain. Exiting gracefully."
  exit 0
fi

# Try to unblock rfkill if wireless is blocked
if command -v rfkill >/dev/null 2>&1; then
  if rfkill list | grep -qi "blocked"; then
    log "RFKill indicates wireless is blocked; attempting to unblock..."
    rfkill unblock all || true
    # give the kernel a moment to react
    sleep 1
  fi
fi

# Try iw reg set with retries
MAX_TRIES=6
SLEEP_BASE=1
success=0
for attempt in $(seq 1 $MAX_TRIES); do
  if iw reg set "$COUNTRY" >/dev/null 2>&1; then
    log "Regulatory domain set to $COUNTRY (transient) on attempt $attempt."
    success=1
    break
  else
    log "iw reg set attempt $attempt failed; retrying after $((SLEEP_BASE*attempt))s"
    sleep $((SLEEP_BASE*attempt))
  fi
done

if [ "$success" -ne 1 ]; then
  log "iw reg set failed after $MAX_TRIES attempts; writing persistent fallbacks."
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
log "iw reg get output:";
iw reg get | sed -n '1,120p' || true

exit 0
