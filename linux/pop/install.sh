#!/usr/bin/env bash
# install.sh: copy the Pop!_OS maintenance scripts into /usr/local/sbin.
# Validates syntax on every script first, so a typo never gets installed.
set -euo pipefail
cd "$(dirname "$0")"

SCRIPTS=(maint-apply.sh maint-check.sh)

for s in "${SCRIPTS[@]}"; do
    bash -n "$s" || { echo "Syntax error in $s. Nothing installed." >&2; exit 1; }
done

for s in "${SCRIPTS[@]}"; do
    sudo install -o root -g root -m 755 "$s" "/usr/local/sbin/$s"
    echo "Installed /usr/local/sbin/$s"
done
