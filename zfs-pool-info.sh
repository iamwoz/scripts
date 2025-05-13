#!/bin/bash

# Usage: ./zfs-woz-faulted-row-highlight.sh <poolname|--all>
set -euo pipefail

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <poolname|--all>"
  exit 1
fi

get_devices_for_pool() {
  local pool="$1"
  zpool status -P "$pool" | grep -oE '/dev/[^ ]+' | sort -u
}

get_device_states_for_pool() {
  local pool="$1"
  declare -gA DEV_STATES
  while read -r line; do
    if [[ "$line" =~ (/dev/[^[:space:]]+)[[:space:]]+([A-Z]+) ]]; then
      DEV_PATH="${BASH_REMATCH[1]}"
      STATE="${BASH_REMATCH[2]}"
      DEV_STATES["$DEV_PATH"]="$STATE"
    fi
  done < <(zpool status -v -P "$pool")
}

resolve_sd() {
  local dev="$1"
  local sd_dev
  sd_dev=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1)
  [[ -n "$sd_dev" ]] && echo "/dev/$sd_dev" || echo "N/A"
}

resolve_sg() {
  local sd_dev="$1"
  local sd_base
  sd_base=$(basename "$sd_dev")
  local dev_dir="/sys/block/$sd_base/device"
  if [[ -d "$dev_dir" ]]; then
    for sg in /sys/class/scsi_generic/sg*; do
      if [[ "$(readlink -f "$sg/device")" == "$(readlink -f "$dev_dir")" ]]; then
        echo "/dev/$(basename "$sg")"
        return
      fi
    done
  fi
  echo "N/A"
}

get_disk_info() {
  local sd_dev="$1"
  lsblk -S -o NAME,VENDOR,MODEL,SERIAL | awk -v dev="$(basename "$sd_dev")" '$1 == dev {print $2, $3, $4}'
}

print_header() {
  printf "%-60s %-6s %-10s %-24s %-22s %-10s %-10s %-10s\n" \
    "Device" "Size" "Vendor" "Model" "Serial" "/dev/sdX" "/dev/sgX" "STATE"
  printf "%s\n" "$(printf '%.0s-' {1..160})"
}

print_device_info() {
  local partuuid_dev="$1"
  local raw_state="${DEV_STATES[$partuuid_dev]:-UNKNOWN}"

  local size sd_dev sg_dev vendor model serial
  size=$(lsblk "$partuuid_dev" -o SIZE -dn 2>/dev/null || echo "N/A")
  sd_dev=$(resolve_sd "$partuuid_dev")
  sg_dev=$(resolve_sg "$sd_dev")
  read -r vendor model serial <<< "$(get_disk_info "$sd_dev")"

  local format="%-60s %-6s %-10s %-24s %-22s %-10s %-10s %-10s\n"
  if [[ "$raw_state" == "FAULTED" ]]; then
    printf "\033[31m$format\033[0m" \
      "$partuuid_dev" "$size" "${vendor:-N/A}" "${model:-N/A}" "${serial:-N/A}" "$sd_dev" "$sg_dev" "$raw_state"
  else
    printf "$format" \
      "$partuuid_dev" "$size" "${vendor:-N/A}" "${model:-N/A}" "${serial:-N/A}" "$sd_dev" "$sg_dev" "$raw_state"
  fi
}

if [[ "$1" == "--all" ]]; then
  pools=$(zpool list -H -o name)
else
  pools="$1"
fi

print_header
declare -A seen

for pool in $pools; do
  echo "Pool: $pool"
  get_device_states_for_pool "$pool"

  for dev in $(get_devices_for_pool "$pool"); do
    if [[ -z "${seen[$dev]+x}" ]]; then
      print_device_info "$dev"
      seen[$dev]=1
    fi
  done
  echo
done
