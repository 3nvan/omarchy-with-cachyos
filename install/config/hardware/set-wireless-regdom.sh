#!/usr/bin/env bash
set -euo pipefail

# Robust, idempotent script to set wireless regulatory domain with retries and
# improved logging. Usage: set-wireless-regdom.sh [CC]
# Where CC is an ISO 3166-1 alpha-2 country code (default: US)

COUNTRY="${1:-US}"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*"; }

# Ensure running under bash for consistent behavior
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# Ensure we run as root. Re-exec under sudo if needed.
if [ "$(id -u)" -ne 0 ]; then
  log "Not root: re-running under sudo to set regulatory domain..."
  exec sudo bash "$0" "$@"
fi

# Wait for `iw` to become available (up to 15s). Some installer flows install
# tools asynchronously, so this avoids a hard failure if `iw` appears shortly.
WAIT_IW=15
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
MAX_TRIES=3
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
