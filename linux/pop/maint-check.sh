#!/usr/bin/env bash
#
# maint-check.sh: A non-destructive system maintenance checker for my Pop!_OS host.
# Fetches/refreshes package metadata and reports pending work, but doesn't apply anything.
#
set -uo pipefail

# --- Configuration ---
LOGFILE=/var/log/maint-check.log
CACHEFILE=/run/maint-pending            #tmpfs; cleared on reboot & instant to read
LOCKFILE=/run/lock/maint-check.lock

# --- Helpers ---
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOGFILE"; }

# --- Single-instance Guard ---
exec 9>"$LOCKFILE" || { echo "cannot open lock" >&2; exit 1; }
if ! flock -n 9; then
    log "another instance is running. Exiting..."
    exit 0
fi

log "=== Maintenance Check START (pid $$) ==="

# --- APT: Refresh indices, then simulate an upgrade to count pending ---
if ! apt-get update -qq -o Acquire::Retries=3 2>>"$LOGFILE"; then
    log "WARN: apt-get update returned non-zero"
fi

APT_SIM="$(LC_ALL=C apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null)"
APT_PENDING="$(printf '%s\n' "$APT_SIM" | grep -c '^Inst')"
APT_SECURITY="$(printf '%s\n' "$APT_SIM" | grep '^Inst' | grep -ci security)"
log "APT: ${APT_PENDING} upgradable (${APT_SECURITY} security)"

# --- Flatpak: Query remote for available without applying ---
FLATPAK_PENDING=0
if command -v flatpak >/dev/null 2>&1; then
    FLATPAK_PENDING="$(flatpak remote-ls --updates 2>/dev/null | grep -c . || true)"
    log "Flatpak: ${FLATPAK_PENDING} update(s) available"
fi

# --- Firmware: Refresh LVFS metadata, count device updates ---
FW_PENDING=0
if command -v fwupdmgr >/dev/null 2>&1; then
    fwupdmgr refresh --force --no-progress >/dev/null 2>>"$LOGFILE" || true
    if command -v jq >/dev/null 2>&1; then
        FW_PENDING="$(fwupdmgr get-updates --json 2>/dev/null | jq '[.Devices[]?.Releases[]?] | length' 2>/dev/null || echo 0)"
    else
        FW_PENDING="$(fwupdmgr get-updates --no-progress 2>/dev/null | grep -ci 'new version' || true)"
    fi
    log "Firmware: ${FW_PENDING} device update(s) available"
fi

# --- Pop!_OS release availabilty (feature upgrade, not applied) ---
POP_RELEASE="none"
if command -v pop-upgrade >/dev/null 2>&1; then
    if pop-upgrade release check 2>/dev/null | grep -qi 'update is available'; then
        POP_RELEASE="available"
    fi
    log "Pop release upgrade: ${POP_RELEASE}"
fi

# --- Disk pressure ---
ROOT_USE="$(df -h --output=pcent / | tail -1 | tr -d ' %')"
BOOT_USE="$(df -h --output=pcent /boot 2>/dev/null | tail -1 | tr -d ' %' || echo 0)"
log "Disk: / at ${ROOT_USE}% , /boot at ${BOOT_USE}%"
[ "${ROOT_USE:-0}" -ge 85 ] 2>/dev/null && log "WARN: / above 85%"
[ "${BOOT_USE:-0}" -ge 80 ] 2>/dev/null && log "WARN: /boot above 80%"

# --- dpkg Health: Packages not in the fully-installed 'ii' state ---
DPKG_BAD="$(dpkg -l 2>/dev/null | awk '/^[a-z]/ && $1 !~ /^ii$/ {c++} END{print c+0}')"
log "dpkg: ${DPKG_BAD} package(s) not in clean 'ii' state"

# --- Write the cache for instant shell consumption ---
{
    printf 'apt=%s\n'      "$APT_PENDING"
    printf 'security=%s\n' "$APT_SECURITY"
    printf 'flatpak=%s\n'  "$FLATPAK_PENDING"
    printf 'firmware=%s\n' "$FW_PENDING"
    printf 'pop=%s\n'      "$POP_RELEASE"
    printf 'root_pct=%s\n' "$ROOT_USE"
    printf 'boot_pct=%s\n' "$BOOT_USE"
    printf 'dpkg_bad=%s\n' "$DPKG_BAD"
    printf 'checked=%s\n'  "$(date '+%Y-%m-%d %H:%M')"
} >"$CACHEFILE.tmp" && mv "$CACHEFILE.tmp" "$CACHEFILE"

log "=== Maintenance Check END ==="
exit 0