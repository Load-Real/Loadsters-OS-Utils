#!/usr/bin/env bash
#
# maint-apply.sh: Interactive and destructive system maintenance for Pop!_OS.
# Run manually, as needed, from a terminal. Zero sandboxing or scheduling.
# Applies updates the companion script maint-check.sh reports on.

# -u           : treat unset variables as errors (catches typos in names).
# -o pipefail  : a pipeline fails if ANY command in it fails, not just the last.
# Deliberately NOT using -e, because this script inspects exit codes itself
# and decides what is fatal. With -e, a harmless non-zero (like grep finding
# nothing) would kill the script.
set -uo pipefail

# ===========================================================================
# CONFIGURATION
# ===========================================================================

# Where per-run logs go. One file per run, timestamped.
LOGDIR=/var/log/maint-apply
LOGFILE="${LOGDIR}/apply-$(date '+%Y%m%d-%H%M%S').log"

# Command-line toggles (set by argument parsing below).
ASSUME_YES=0      # -y: auto-answer ordinary confirm() prompts
SKIP_FIRMWARE=0   # --no-firmware
SKIP_FLATPAK=0    # --no-flatpak

# Persistent state. Lives in /var/lib (not /run, which is wiped on boot)
# because the failure marker matters most right before and after a reboot.
# The directory is created on demand by mark_failed().
STATE_DIR=/var/lib/maint-apply
FAIL_MARKER="${STATE_DIR}/LAST_RUN_FAILED"

# Run-wide status flags.
APT_FAILED=0       # set to 1 if any apt/dpkg step fails
REBOOT_BLOCKED=0   # set to 1 if post-run checks say rebooting is unsafe

# Packages whose REMOVAL must never happen without a typed confirmation.
# Matched against package names (the part after "Remv"/"Purg" in apt's
# simulation output). Old kernels are deliberately NOT listed here, because
# autoremove routinely and correctly removes them.
#   nvidia-driver-*        : the metapackage that holds the whole driver stack
#   nvidia-dkms-*          : the kernel module source DKMS builds from
#   libnvidia-gl-*         : EGL/GL libraries COSMIC needs on Wayland
#   system76-driver-nvidia : Pop's metapackage that pulls the driver series
#   cosmic-*               : the desktop itself
PROTECTED_RE='^(nvidia-driver-|nvidia-dkms-|libnvidia-gl-|system76-driver-nvidia|cosmic-)'

# Also protect the CURRENTLY RUNNING kernel's image and modules. Removing the
# kernel you are running from is never something to do by accident.
# (The dots in the version string are regex wildcards here, which is harmless.)
PROTECTED_RE="${PROTECTED_RE}|^linux-(image|modules)-$(uname -r)\$"

# ===========================================================================
# COLORS
# ===========================================================================
# Only emit ANSI color codes when stdout is a real terminal. If output is
# piped or redirected, fall back to plain text.
if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[0;31m'; GRN=$'\033[0;32m'
    YLW=$'\033[0;33m'; BLU=$'\033[0;34m'; CYN=$'\033[0;36m'; RST=$'\033[0m'
else
    BOLD=''; RED=''; GRN=''; YLW=''; BLU=''; CYN=''; RST=''
fi

# ===========================================================================
# HELPERS: output
# ===========================================================================
# Every output helper prints to the screen AND appends to the log via tee.
# NOTE: these assume LOGDIR exists, so they must not be used before the
# 'mkdir -p "$LOGDIR"' line further down.

ts()   { date '+%Y-%m-%d %H:%M:%S'; }                                         # timestamp
say()  { printf '%s\n' "$*" | tee -a "$LOGFILE"; }                            # plain line
hdr()  { printf '\n%s══ %s ══%s\n' "$BOLD$BLU" "$*" "$RST" | tee -a "$LOGFILE"; }  # section header
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*" | tee -a "$LOGFILE"; }        # success
warn() { printf '%s⚠%s  %s\n' "$YLW" "$RST" "$*" | tee -a "$LOGFILE"; }       # warning
err()  { printf '%s✗%s %s\n' "$RED" "$RST" "$*" | tee -a "$LOGFILE"; }        # error

# ===========================================================================
# HELPERS: failure tracking and logged execution
# ===========================================================================

# mark_failed "message"
# Records a failure in the persistent marker file AND prints it as an error.
# Appends (>>) rather than overwrites, so multiple failures in one run, or a
# failure on top of an earlier uncleared one, are all kept.
mark_failed() {
    mkdir -p "$STATE_DIR"
    printf '%s  %s\n  Log: %s\n' "$(ts)" "$*" "$LOGFILE" >> "$FAIL_MARKER"
    err "$*"
}

# run_logged command [args...]
# Runs a command, shows its output live, and captures stdout+stderr in the log.
# This is what fixes "the real error was only on screen". Usage:
#   if run_logged apt-get update; then ...
run_logged() {
    # Echo the command being run, so the log shows exactly what executed.
    say "${CYN}\$ $*${RST}"
    # "$@" re-expands the arguments with their original quoting intact.
    # 2>&1 merges stderr into stdout so tee captures both.
    "$@" 2>&1 | tee -a "$LOGFILE"
    # PIPESTATUS is an array of exit codes from the last pipeline.
    # Index 0 is the command itself, index 1 would be tee. Returning [0]
    # means callers see the command's real success or failure.
    return "${PIPESTATUS[0]}"
}

# ===========================================================================
# HELPERS: prompts
# ===========================================================================

# confirm "prompt"
# Ordinary yes/no prompt. Returns 0 for yes, 1 for no. Default is NO.
# Honors ASSUME_YES (-y), in which case it logs the prompt and says yes.
confirm() {
    local prompt="$1" reply
    if [ "$ASSUME_YES" -eq 1 ]; then
        say "${CYN}?${RST} ${prompt} [auto-yes]"
        return 0
    fi
    printf '%s?%s %s [y/N] ' "$CYN" "$RST" "$prompt"
    # If read fails (no terminal, Ctrl-D), reply stays empty and we fall
    # through to the default "no" below.
    read -r reply || true
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# confirm_hard "prompt"
# High-stakes prompt for protected removals. IGNORES ASSUME_YES on purpose,
# because a driver removal should never be skippable by a flag.
# Requires typing the literal word YES (capitals). Anything else is "no".
# If read fails (no terminal attached), the answer is "no" by default.
confirm_hard() {
    local prompt="$1" reply
    printf '%s!%s %s\n  Type %sYES%s to continue: ' "$RED" "$RST" "$prompt" "$BOLD" "$RST"
    read -r reply || return 1
    [ "$reply" = "YES" ]
}

# ===========================================================================
# HELPERS: plan parsing and post-run checks
# ===========================================================================

# count "multi-line string"
# Counts lines in a string, treating an empty string as zero. Needed because
# 'printf "%s\n" ""' still emits one (empty) line, which wc would count as 1.
count() {
    if [ -n "$1" ]; then
        printf '%s\n' "$1" | wc -l
    else
        echo 0
    fi
}

# nvidia_gate KERNEL_VERSION
# Checks that the NVIDIA kernel module ON DISK for the given kernel matches
# the installed NVIDIA userspace libraries. This predicts the state AFTER a
# reboot, unlike nvidia-smi, which only reports on the module loaded now.
# Returns 0 if they match, 1 if the module is missing or mismatched.
nvidia_gate() {
    local k="$1" mod lib
    # libnvidia-ml.so.<version> is the NVML library nvidia-smi uses. Its file
    # suffix is the userspace driver version (e.g. 595.104.02). If more than
    # one is present, take the highest version.
    lib="$(ls /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.*.* 2>/dev/null \
        | sed 's/.*\.so\.//' | sort -V | tail -1)"
    # modinfo -k reads the module for the named kernel, not the running one.
    mod="$(modinfo -k "$k" -F version nvidia 2>/dev/null)"
    if [ -z "$mod" ]; then
        err "No NVIDIA module built for ${k} (userspace: ${lib:-none})"
        return 1
    fi
    if [ "$mod" != "$lib" ]; then
        err "NVIDIA mismatch on ${k}: module ${mod}, userspace ${lib}"
        return 1
    fi
    ok "NVIDIA ${mod} matches userspace on ${k}."
}

# ===========================================================================
# ARGUMENT PARSING
# ===========================================================================
# Note: the log directory does not exist yet at this point, so errors here
# use plain printf to stderr instead of err() (which would try to tee into a
# log file that cannot be created yet).
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)        ASSUME_YES=1 ;;
        --no-firmware)   SKIP_FIRMWARE=1 ;;
        --no-flatpak)    SKIP_FLATPAK=1 ;;
        -h|--help)
            cat <<'HELP'
maint-apply.sh: Interactive system maintenance (applies updates)
Usage: sudo maint-apply.sh [options]
  -y, --yes         Skip ordinary confirmation prompts (dangerous)
                    Protected-removal prompts still require typing YES,
                    and a failed health check still blocks the reboot.
      --no-firmware Skip the fwupdmgr firmware step
      --no-flatpak  Skip the flatpak update step
  -h, --help        Display this help menu
HELP
            exit 0 ;;
        # Fixed format string with %s. Putting "$1" directly inside the
        # format would let a '%' in the argument be read as a specifier.
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# ===========================================================================
# STARTUP: root check, log directory, run-start reference
# ===========================================================================
if [ "$(id -u)" -ne 0 ]; then
    printf 'This script must be run as root. Re-run with: sudo %s %s\n' "$0" "$*" >&2
    exit 1
fi

mkdir -p "$LOGDIR"

# A temp file created NOW gives a fixed timestamp for "since this run began".
# Used later with 'find -newer' to locate DKMS build logs written during this
# run. (The log file itself can't serve this purpose, because every write
# to it updates its modification time.)
RUN_START_REF="$(mktemp /tmp/maint-apply-start.XXXXXX)"
# The EXIT trap fires on every exit path, including early 'exit 1's, so the
# temp file never gets left behind.
trap 'rm -f "$RUN_START_REF"' EXIT

say "${BOLD}Maintenance apply run start $(ts)${RST}"
say "Logging to: $LOGFILE"

# ===========================================================================
hdr "Preflight"
# ===========================================================================
# Refuse to build a new upgrade on top of an already broken system. Starting
# a fresh transaction over half-configured packages is how one failure
# becomes two.

# 1. Was a previous run left in a failed state?
#    -s means "file exists AND is not empty".
if [ -s "$FAIL_MARKER" ]; then
    warn "A previous run FAILED and was never cleared:"
    sed 's/^/    /' "$FAIL_MARKER" | tee -a "$LOGFILE"
    confirm "Continue (this run may finish the repair)?" || exit 1
fi

# 2. Is the dpkg database consistent?
#    'dpkg --audit' prints NOTHING when everything is fully configured, which
#    makes it a clean yes/no test. Any output means unpacked-but-unconfigured
#    or otherwise broken packages.
AUDIT="$(dpkg --audit 2>&1)"
if [ -n "$AUDIT" ]; then
    printf '%s\n' "$AUDIT" | tee -a "$LOGFILE"
    mark_failed "dpkg has half-configured packages. Run: sudo dpkg --configure -a"
    exit 1
fi
ok "dpkg database consistent."

# 3. Is the DKMS tree readable?
#    A broken entry (e.g. a module directory whose source/dkms.conf is gone)
#    makes every 'dkms' call print "Error!". It sat in this tree before the
#    Oct 2026 failure, so it is treated as a stop sign.
if command -v dkms >/dev/null 2>&1; then
    if dkms status 2>&1 | grep -q '^Error!'; then
        dkms status 2>&1 | tee -a "$LOGFILE"
        mark_failed "DKMS tree has broken entries. Fix them before upgrading."
        exit 1
    fi
    ok "DKMS tree readable."
fi

# 4. Is there room on the EFI System Partition?
#    On Pop!_OS, kernelstub copies every new kernel and initrd into /boot/efi.
#    A full ESP makes a kernel install fail in the same way a DKMS failure
#    does. The threshold is a warning, not a stop, so tune it to your ESP.
ESP_FREE_MB="$(df -m --output=avail /boot/efi 2>/dev/null | tail -1 | tr -d ' ')"
if [ -n "$ESP_FREE_MB" ] && [ "$ESP_FREE_MB" -lt 300 ]; then
    warn "Only ${ESP_FREE_MB} MB free on the ESP. kernelstub may fail to copy a new kernel."
fi

# Track whether a reboot becomes necessary, and why.
REBOOT_REQUIRED=0
REBOOT_REASONS=()

# ===========================================================================
hdr "APT: Refresh package indices"
# ===========================================================================
# --error-on=any : by default apt-get update can exit 0 even when some
#                  repositories failed to fetch (it warns and keeps the stale
#                  index). This makes ANY fetch failure an error, which matters
#                  on restricted networks. A half-refreshed index can produce a
#                  plan that mixes package snapshots.
# Acquire::Retries=3 : retry transient download failures before giving up.
if run_logged apt-get update --error-on=any -o Acquire::Retries=3; then
    ok "Indices refreshed."
else
    err "apt-get update failed. Aborting before any upgrade."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the PLAN by simulating the SAME command that will actually run.
# ---------------------------------------------------------------------------
# apt-get -s (simulate) prints one line per action without changing anything:
#   Inst pkg [oldver] (newver ...)  -> an UPGRADE (has [oldver])
#   Inst pkg (newver ...)           -> a NEW install (no [oldver])
#   Remv pkg [ver]                  -> a removal
#   Purg pkg [ver]                  -> a removal including config files
#   Conf pkg (...)                  -> configure step (ignored here)
# LC_ALL=C forces English output, so these keywords are reliable to grep.
PLAN="$(LC_ALL=C apt-get -s full-upgrade 2>/dev/null)"
INST="$(printf '%s\n' "$PLAN" | grep '^Inst ' || true)"
REMV="$(printf '%s\n' "$PLAN" | grep -E '^(Remv|Purg) ' || true)"

# Split installs into upgrades vs brand-new packages, using the "[oldver]"
# marker. A new kernel (linux-image-X.Y.Z) shows up as a NEW install, which
# is exactly what the old 'apt-get -s upgrade' preview could never show.
UPG="$(printf '%s\n' "$INST" | grep -E '^Inst [^ ]+ \[' || true)"
# 'grep .' drops the empty line left behind when INST is empty.
NEW="$(printf '%s\n' "$INST" | grep -vE '^Inst [^ ]+ \[' | grep . || true)"

UPG_COUNT="$(count "$UPG")"
NEW_COUNT="$(count "$NEW")"
REMV_COUNT="$(count "$REMV")"
# Rough security count: lines whose source archive mentions "security".
# 'grep -c' prints 0 and exits 1 on no match, so '|| true' keeps pipefail quiet.
SEC_COUNT="$(printf '%s\n' "$INST" | grep -ci security || true)"

# Which removals hit the protected list? awk '{print $2}' pulls the package
# name out of "Remv pkg [ver]". Multi-arch names keep their suffix
# (e.g. libnvidia-gl-580:i386), which still matches the ^prefix patterns.
PROT_HITS="$(printf '%s\n' "$REMV" | awk '{print $2}' | grep -E "$PROTECTED_RE" || true)"

if [ "$UPG_COUNT" -eq 0 ] && [ "$NEW_COUNT" -eq 0 ] && [ "$REMV_COUNT" -eq 0 ]; then
    ok "Nothing to upgrade. System is current on APT packages."
else
    say ""
    say "${BOLD}${UPG_COUNT}${RST} upgrade(s), ${BOLD}${NEW_COUNT}${RST} new install(s), ${BOLD}${REMV_COUNT}${RST} removal(s) (${BOLD}${SEC_COUNT}${RST} security)."

    # -----------------------------------------------------------------------
    # Detect reboot-sensitive changes for reboot planning.
    # These scan INST (upgrades AND new installs), so a brand-new kernel
    # package is caught. NVIDIA_HIT also scans removals, so a driver package
    # disappearing counts as a driver change.
    # -----------------------------------------------------------------------
    KERNEL_HIT="$(printf '%s\n' "$INST" | grep -E '^Inst (linux-image|linux-headers|linux-generic|linux-system76)' || true)"
    NVIDIA_HIT="$(printf '%s\n%s\n' "$INST" "$REMV" | grep -Ei '^(Inst|Remv|Purg) (nvidia|system76-driver|libnvidia)' || true)"
    INITRD_HIT="$(printf '%s\n' "$INST" | grep -Ei '^Inst (systemd|dbus|libc6)' || true)"

    # -----------------------------------------------------------------------
    # Show the full plan in three groups.
    # -----------------------------------------------------------------------
    say ""
    if [ -n "$UPG" ]; then
        say "${CYN}Upgrades:${RST}"
        printf '%s\n' "$UPG" | sed 's/^Inst /  • /' | tee -a "$LOGFILE"
    fi
    if [ -n "$NEW" ]; then
        say "${CYN}New installs:${RST}"
        printf '%s\n' "$NEW" | sed 's/^Inst /  + /' | tee -a "$LOGFILE"
    fi
    if [ -n "$REMV" ]; then
        say "${YLW}Removals:${RST}"
        printf '%s\n' "$REMV" | sed -E 's/^(Remv|Purg) /  - /' | tee -a "$LOGFILE"
    fi

    if [ -n "$KERNEL_HIT" ]; then
        warn "Kernel packages will change. REBOOT will be required."
        REBOOT_REQUIRED=1; REBOOT_REASONS+=("kernel update")
    fi
    if [ -n "$NVIDIA_HIT" ]; then
        warn "NVIDIA/driver packages will change. REBOOT required to avoid NVML mismatch."
        REBOOT_REQUIRED=1; REBOOT_REASONS+=("NVIDIA/driver update")
    fi
    if [ -n "$INITRD_HIT" ]; then
        warn "Core system libs (systemd/libc/dbus) will change. Reboot strongly advised."
        REBOOT_REQUIRED=1; REBOOT_REASONS+=("core system libraries")
    fi

    # -----------------------------------------------------------------------
    # PROTECTED-REMOVAL GATE
    # If the plan removes anything on the protected list, stop and require a
    # typed YES. This is what would have caught nvidia-driver-580-open being
    # dropped on Oct 18. Declining exits cleanly with nothing changed.
    # -----------------------------------------------------------------------
    if [ -n "$PROT_HITS" ]; then
        err "This plan REMOVES protected packages:"
        printf '%s\n' "$PROT_HITS" | sed 's/^/    • /' | tee -a "$LOGFILE"
        say "  This usually means a driver series transition or a broken dependency."
        if ! confirm_hard "Proceed anyway?"; then
            warn "Aborted at protected-removal gate. Nothing changed."
            exit 0
        fi
    fi

    # -----------------------------------------------------------------------
    # EXECUTE the plan in two phases.
    #   Phase 1 (--download-only): fetch every .deb into the apt cache.
    #           Nothing is installed, so a network failure here is harmless.
    #   Phase 2 (--no-download): install strictly from the cache. A dropped
    #           connection can no longer interrupt dpkg halfway through.
    # Using -y is acceptable here, because you just approved this exact plan,
    # removals included. (dpkg may still ask about changed config files, and
    # that prompt stays interactive.)
    # -----------------------------------------------------------------------
    say ""
    if confirm "Proceed with this exact plan?"; then
        if ! run_logged apt-get full-upgrade -y --download-only; then
            mark_failed "Package download failed. Nothing was installed."
            APT_FAILED=1
        elif ! run_logged apt-get full-upgrade -y --no-download; then
            mark_failed "full-upgrade failed during install/configure. DO NOT REBOOT until resolved."
            # Pull the tail of any DKMS build log written during THIS run,
            # so the actual compiler or patch error lands in the log.
            find /var/lib/dkms -name make.log -newer "$RUN_START_REF" 2>/dev/null | while read -r f; do
                say "--- $f (tail)"
                tail -n 25 "$f" | tee -a "$LOGFILE"
            done
            APT_FAILED=1
        else
            ok "Full upgrade complete."
        fi
    else
        warn "Skipped apt full-upgrade at user request."
    fi
fi

# ===========================================================================
# CLEANUP / FLATPAK / FIRMWARE
# All of these are skipped if the APT step failed. Removing packages or
# flashing firmware on top of a half-finished upgrade only makes recovery
# harder.
# ===========================================================================
if [ "$APT_FAILED" -eq 0 ]; then

    # =======================================================================
    hdr "APT: Remove orphaned dependencies & old kernels"
    # =======================================================================
    # Simulate with --purge, matching the real command exactly. With --purge,
    # apt prints "Purg" lines instead of "Remv", so match both.
    AUTOREMOVE_SIM="$(LC_ALL=C apt-get -s autoremove --purge 2>/dev/null | grep -E '^(Remv|Purg) ' || true)"
    if [ -z "$AUTOREMOVE_SIM" ]; then
        ok "No orphaned packages to remove."
    else
        say "${CYN}Would remove:${RST}"
        printf '%s\n' "$AUTOREMOVE_SIM" | sed -E 's/^(Remv|Purg) /  • /' | tee -a "$LOGFILE"

        # Same protected-removal check as the upgrade plan. autoremove is the
        # step that would finish off a driver stack whose metapackage vanished
        # (everything it pulled in becomes "no longer required").
        AR_OK=1
        AR_PROT="$(printf '%s\n' "$AUTOREMOVE_SIM" | awk '{print $2}' | grep -E "$PROTECTED_RE" || true)"
        if [ -n "$AR_PROT" ]; then
            err "autoremove would remove protected packages:"
            printf '%s\n' "$AR_PROT" | sed 's/^/    • /' | tee -a "$LOGFILE"
            say "  To keep one: sudo apt-mark manual <package>"
            confirm_hard "Proceed anyway?" || AR_OK=0
        fi

        say ""
        if [ "$AR_OK" -eq 1 ] && confirm "Proceed with 'apt-get autoremove --purge'?"; then
            if run_logged apt-get autoremove --purge -y; then
                ok "Orphans removed."
            else
                # A dpkg failure during removal is as dangerous as one during
                # install, so it is treated as a real failure.
                mark_failed "autoremove failed. DO NOT REBOOT until resolved."
                APT_FAILED=1
            fi
        else
            warn "Skipped autoremove."
        fi
    fi

    # =======================================================================
    hdr "APT: Prune obsolete cached .deb archives"
    # =======================================================================
    # autoclean only removes .debs that can no longer be downloaded (i.e.
    # superseded versions). It keeps current ones, unlike 'apt-get clean'.
    CACHE_SIZE="$(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1 || echo '?')"
    say "Current archive cache size: ${BOLD}${CACHE_SIZE}${RST}"
    if confirm "Run 'apt-get autoclean' (removes only obsolete .debs, keeps current)?"; then
        run_logged apt-get autoclean && ok "Autoclean done."
    else
        warn "Skipped autoclean."
    fi

    # =======================================================================
    # Flatpak (system installation only, since this runs as root)
    # =======================================================================
    if [ "$SKIP_FLATPAK" -eq 0 ] && command -v flatpak >/dev/null 2>&1; then
        hdr "Flatpak: Update apps & runtimes"
        FP_UPDATES="$(flatpak remote-ls --updates 2>/dev/null || true)"
        if [ -z "$FP_UPDATES" ]; then
            ok "All flatpaks current."
        else
            say "${CYN}Updates available:${RST}"
            printf '%s\n' "$FP_UPDATES" | sed 's/^/  • /' | tee -a "$LOGFILE"
            say ""
            if confirm "Run 'flatpak update'?"; then
                flatpak update -y && ok "Flatpaks updated."
            else
                warn "Skipped flatpak update."
            fi
        fi
        # Offer to prune unused runtimes regardless.
        if confirm "Also prune unused flatpak runtimes ('flatpak uninstall --unused')?"; then
            flatpak uninstall --unused -y && ok "Unused runtimes pruned."
        fi
    fi

    # =======================================================================
    # Firmware (LVFS via fwupd)
    # =======================================================================
    # Re-checks APT_FAILED because autoremove (above) can set it.
    if [ "$SKIP_FIRMWARE" -eq 0 ] && [ "$APT_FAILED" -eq 0 ] && command -v fwupdmgr >/dev/null 2>&1; then
        hdr "Firmware: LVFS updates"
        fwupdmgr refresh --force >/dev/null 2>&1 || true

        # fwupdmgr get-updates exit codes:
        #   0 = updates available
        #   2 = nothing to do
        #   anything else = an actual error (network, daemon, etc.)
        # The old version treated "error" the same as "no updates".
        # Capture output once, then branch on the code. $? after an
        # assignment from $(...) is the exit code of the command inside.
        FW_OUT="$(fwupdmgr get-updates 2>&1)"; FW_RC=$?
        case "$FW_RC" in
            0)
                say "${CYN}Firmware updates available:${RST}"
                printf '%s\n' "$FW_OUT" | tee -a "$LOGFILE"
                say ""
                warn "Firmware updates may require a cold reboot / power cycle to apply."
                if confirm "Run 'fwupdmgr update'?"; then
                    if fwupdmgr update; then
                        ok "Firmware update staged/applied."
                        REBOOT_REQUIRED=1; REBOOT_REASONS+=("firmware update")
                    else
                        warn "fwupdmgr update returned non-zero (may be 'nothing to do' or needs reboot)."
                    fi
                else
                    warn "Skipped firmware update."
                fi
                ;;
            2)
                ok "No firmware updates available."
                ;;
            *)
                warn "fwupdmgr error (rc=${FW_RC}). Restricted network?"
                printf '%s\n' "$FW_OUT" | tee -a "$LOGFILE"
                ;;
        esac
    fi

else
    warn "Skipping cleanup, Flatpak and firmware because APT failed."
fi

# ===========================================================================
hdr "Post-run Health & Reboot Assessment"
# ===========================================================================

# ---------------------------------------------------------------------------
# Kernels: running, newest installed, and the one that will actually boot.
# ---------------------------------------------------------------------------
RUNNING_KERNEL="$(uname -r)"

# Newest kernel image in /boot, by version sort.
NEWEST_KERNEL="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)"
# (A pipeline ending in tail always "succeeds", so '|| echo ?' would never
# fire. Test for empty output instead.)
[ -z "$NEWEST_KERNEL" ] && NEWEST_KERNEL='?'

# The kernel that will actually boot. On Pop!_OS, /boot/vmlinuz is a symlink
# to the default kernel, updated by the kernel package's postinst. If that
# postinst FAILS (as on Oct 18), the symlink still points at the OLD kernel,
# even though a newer image sits on disk. That old kernel is the one you
# actually boot into, so it is the one that must pass the checks below.
NEXT_BOOT_KERNEL="$(readlink -f /boot/vmlinuz 2>/dev/null | sed 's|.*/vmlinuz-||')"
[ -z "$NEXT_BOOT_KERNEL" ] && NEXT_BOOT_KERNEL="$NEWEST_KERNEL"

say "Running kernel:   ${BOLD}${RUNNING_KERNEL}${RST}"
say "Newest on disk:   ${BOLD}${NEWEST_KERNEL}${RST}"
say "Next boot kernel: ${BOLD}${NEXT_BOOT_KERNEL}${RST}"

if [ "$RUNNING_KERNEL" != "$NEWEST_KERNEL" ] && [ "$NEWEST_KERNEL" != '?' ]; then
    warn "Running kernel differs from newest installed. Reboot to activate ${NEWEST_KERNEL}."
    REBOOT_REQUIRED=1; REBOOT_REASONS+=("newer kernel on disk than running")
fi

# ---------------------------------------------------------------------------
# Packages that explicitly asked for a reboot.
# ---------------------------------------------------------------------------
# Debian/Ubuntu packages touch /run/reboot-required (and list themselves in
# /run/reboot-required.pkgs) when they need a reboot to take effect.
if [ -f /run/reboot-required ]; then
    warn "/run/reboot-required exists (a package requested a reboot)."
    REBOOT_REQUIRED=1; REBOOT_REASONS+=("/run/reboot-required present")
    [ -f /run/reboot-required.pkgs ] && {
        say "  Requested by:"
        sed 's/^/    • /' /run/reboot-required.pkgs | tee -a "$LOGFILE"
    }
fi

# ---------------------------------------------------------------------------
# Live NVIDIA state (the module loaded RIGHT NOW).
# ---------------------------------------------------------------------------
# Right after a driver update this is EXPECTED to fail: the old module is
# still loaded while the new libraries are installed. So a failure here means
# "reboot needed", NOT "reboot safe". The gate below decides safety.
if command -v nvidia-smi >/dev/null 2>&1; then
    if ! nvidia-smi >/dev/null 2>&1; then
        warn "nvidia-smi is failing. Likely a driver/library version mismatch. Reboot needed."
        REBOOT_REQUIRED=1; REBOOT_REASONS+=("nvidia-smi mismatch")
    else
        ok "nvidia-smi responds normally."
    fi
fi

# ---------------------------------------------------------------------------
# REBOOT GATE: verify what the NEXT boot will load.
# ---------------------------------------------------------------------------
# Check both the next-boot kernel and the newest kernel. sort -u collapses
# them into one entry when they are the same.
CHECK_KERNELS="$(printf '%s\n%s\n' "$NEXT_BOOT_KERNEL" "$NEWEST_KERNEL" | sort -u)"

# Only gate on NVIDIA if this machine actually has NVIDIA hardware.
if lspci 2>/dev/null | grep -qi nvidia; then
    # The driver metapackage must still be installed. ${db:Status-Abbrev}
    # prints "ii " for fully installed packages, which excludes "rc"
    # leftovers (removed, config files remaining) that a plain glob in
    # 'dpkg -l' would also match.
    if ! dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-driver-*' 2>/dev/null | grep -q '^ii '; then
        err "No nvidia-driver-* metapackage installed."
        REBOOT_BLOCKED=1
    fi
    # $CHECK_KERNELS is deliberately unquoted, so the shell splits it into
    # one kernel version per loop iteration.
    for k in $CHECK_KERNELS; do
        nvidia_gate "$k" || REBOOT_BLOCKED=1
    done
fi

# Every DKMS module registered for these kernels must be cleanly installed.
# 'dkms status -k' filters to one kernel, so stale entries for old kernels
# (like the leftover system76 ones for 7.0.11) don't trip this check.
# Any line that does not end in exactly ": installed" (built-only, added-only,
# or carrying a WARNING) is flagged.
if command -v dkms >/dev/null 2>&1; then
    for k in $CHECK_KERNELS; do
        STATUS="$(dkms status -k "$k" 2>&1)"
        ADDED="$(printf '%s\n' "$STATUS" | grep -E ': added$' || true)"
        BAD="$(printf '%s\n' "$STATUS" | grep . | grep -vE ': (installed|added)$' || true)"
        if [ -n "$ADDED" ]; then
            warn "DKMS modules registered but never built (not blocking):"
            printf '%s\n' "$ADDED" | sed 's/^/    /' | tee -a "$LOGFILE"
        fi
        if [ -n "$BAD" ]; then
            err "DKMS not clean for ${k}:"
            printf '%s\n' "$BAD" | sed 's/^/    /' | tee -a "$LOGFILE"
            REBOOT_BLOCKED=1
        fi
    done
fi

# ---------------------------------------------------------------------------
# Verdict. Failures exit here, BEFORE any reboot prompt. This also closes
# the old -y hole, where a broken run would auto-confirm "Reboot now?".
# ---------------------------------------------------------------------------
say ""
if [ "$REBOOT_BLOCKED" -eq 1 ]; then
    mark_failed "Post-run checks FAILED. DO NOT REBOOT. See errors above."
fi
if [ "$REBOOT_BLOCKED" -eq 1 ] || [ "$APT_FAILED" -eq 1 ]; then
    err "${BOLD}Not offering a reboot.${RST} Resolve the failures above first."
    say "Log saved: $LOGFILE"
    exit 1
fi

# Everything checked out, so clear any stale failure marker. This happens
# BEFORE the reboot prompt on purpose: 'systemctl reboot' returns immediately
# and shutdown begins, so code after it may never run.
rm -f "$FAIL_MARKER"

if [ "$REBOOT_REQUIRED" -eq 1 ]; then
    err "${BOLD}REBOOT REQUIRED.${RST}"
    say "Reasons:"
    for r in "${REBOOT_REASONS[@]}"; do say "  • $r"; done
    say ""
    if confirm "Reboot now?"; then
        say "Rebooting in 5 seconds… (Ctrl-C to abort)"
        sleep 5
        systemctl reboot
    else
        warn "Reboot deferred. Remember to reboot before relying on GPU/kernel."
    fi
else
    ok "${BOLD}No reboot required.${RST} System is fully current."
fi

say ""
say "${BOLD}Maintenance apply run finished $(ts)${RST}"
say "Log saved: $LOGFILE"
exit 0