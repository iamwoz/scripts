#!/bin/bash

set -euo pipefail

# --- Configuration ---
FLASH_COUNT=10
FLASH_DELAY=1  # seconds

# --- Functions ---

print_usage() {
    cat <<EOF
Usage: $0 /dev/sdX|/dev/sgX

Arguments:
  /dev/sdX   Identify a SATA drive by flashing its activity LED
  /dev/sgX   Identify a SAS drive by flashing its activity LED

This script triggers non-destructive activity to help you visually locate a drive using its LED.
EOF
    exit 1
}

check_dependency() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Missing required command: $cmd"
        echo "Please install it with your system's package manager (e.g. apt, yum, slackpkg)."
        exit 1
    fi
}

is_sata() {
    [[ "$1" =~ ^/dev/sd[a-z]$ ]]
}

is_sas() {
    [[ "$1" =~ ^/dev/sg[0-9]+$ ]]
}

flash_sata() {
    local dev="$1"
    check_dependency smartctl
    echo "[INFO] Flashing SATA drive LED on $dev"

    for ((i=1; i<=FLASH_COUNT; i++)); do
        smartctl --test=short "$dev" >/dev/null 2>&1 || echo "[WARN] smartctl failed on $dev"
        sleep "$FLASH_DELAY"
    done

    echo "[DONE] Finished flashing SATA device $dev"
}

flash_sas() {
    local dev="$1"
    check_dependency sg_start
    check_dependency sg_turs
    echo "[INFO] Flashing SAS drive LED on $dev"

    if sg_turs "$dev" >/dev/null 2>&1; then
        echo "[INFO] Using Test Unit Ready (TUR) commands"
        for ((i=1; i<=FLASH_COUNT; i++)); do
            sg_turs "$dev" >/dev/null 2>&1
            sleep "$FLASH_DELAY"
        done
    else
        echo "[INFO] TUR failed, falling back to spin down/up"
        for ((i=1; i<=FLASH_COUNT; i++)); do
            sg_start --stop "$dev" >/dev/null 2>&1
            sleep "$FLASH_DELAY"
            sg_start --start "$dev" >/dev/null 2>&1
            sleep "$FLASH_DELAY"
        done
    fi

    echo "[DONE] Finished flashing SAS device $dev"
}

# --- Main ---

# Argument handling
if [[ $# -ne 1 ]]; then
    echo "[ERROR] Invalid number of arguments."
    print_usage
fi

DEVICE="$1"

# Validate device path and type
if [[ ! -e "$DEVICE" ]]; then
    echo "[ERROR] Device $DEVICE does not exist."
    exit 1
fi

if is_sata "$DEVICE"; then
    flash_sata "$DEVICE"
elif is_sas "$DEVICE"; then
    flash_sas "$DEVICE"
else
    echo "[ERROR] Invalid device format: $DEVICE"
    print_usage
fi
