#!/bin/bash

set -euo pipefail

OPENSEA_CACHE_DIR="${HOME}/.cache/openseachest"
OPENSEA_SMART="${OPENSEA_CACHE_DIR}/openSeaChest_SMART"

echo "[INFO] Checking openSeaChest_SMART availability..."

download_openseachest() {
  echo "[INFO] Downloading latest openSeaChest portable release..."

  mkdir -p "$OPENSEA_CACHE_DIR"
  tmpfile=$(mktemp)

  release_url=$(curl -s https://api.github.com/repos/Seagate/openSeaChest/releases/latest | \
    jq -r '.assets[] | select(.name | test("linux-x86_64-portable\\.tar\\.xz$")) | .browser_download_url' | head -n1)

  if [[ -z "$release_url" ]]; then
    echo "[ERROR] Could not determine download URL from GitHub. Aborting."
    exit 1
  fi

  echo "[INFO] Downloading: $release_url"
  curl -L "$release_url" -o "$tmpfile"

  echo "[INFO] Extracting openSeaChest_SMART to $OPENSEA_CACHE_DIR..."
  tar -xJf "$tmpfile" -C "$OPENSEA_CACHE_DIR" --wildcards '*/openSeaChest_SMART' --strip-components=1
  chmod +x "$OPENSEA_SMART"
  rm "$tmpfile"

  echo "[INFO] openSeaChest_SMART updated to latest version."
}

if [[ ! -x "$OPENSEA_SMART" ]]; then
  echo "[INFO] openSeaChest_SMART not found locally. Preparing it..."
  download_openseachest
else
  local_ver=$("$OPENSEA_SMART" --version 2>/dev/null | grep -i version | awk '{print $NF}' | cut -d- -f1)
  remote_ver=$(curl -s https://api.github.com/repos/Seagate/openSeaChest/releases/latest | jq -r '.tag_name' | sed 's/^v//')

  if [[ "$remote_ver" != "$local_ver" ]]; then
    echo "[INFO] Newer openSeaChest version found ($local_ver → $remote_ver), updating..."
    download_openseachest
  else
    echo "[INFO] openSeaChest_SMART is up-to-date (version $local_ver)."
  fi
fi

get_devices_for_pool() {
  zpool status -P "$1" | grep -oE '/dev/[^ ]+' | sort -u
}

get_device_states_for_pool() {
  declare -gA DEV_STATES
  while read -r line; do
    if [[ "$line" =~ (/dev/[^[:space:]]+)[[:space:]]+([A-Z]+) ]]; then
      DEV_STATES["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done < <(zpool status -v -P "$1")
}

resolve_sd() {
  local dev="$1"
  local pk
  pk=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1)
  [[ -n "$pk" ]] && echo "/dev/$pk" || echo "$dev"
}

resolve_sg() {
  local sd_base sg
  sd_base=$(basename "$1")
  for sg in /sys/class/scsi_generic/sg*; do
    if [[ "$(readlink -f "$sg/device")" == "$(readlink -f "/sys/block/$sd_base/device")" ]]; then
      echo "/dev/$(basename "$sg")"
      return
    fi
  done
  echo "N/A"
}

get_disk_info() {
  local base=$(basename "$1")
  local vendor model serial
  vendor=$(lsblk -S -n -o NAME,VENDOR | awk -v d="$base" '$1==d{print $2}')
  model=$(lsblk -S -n -o NAME,MODEL  | awk -v d="$base" '$1==d{print $2}')
  serial=$(lsblk -S -n -o NAME,SERIAL | awk -v d="$base" '$1==d{print $2}')
  echo "$vendor|$model|$serial"
}

get_year_and_written() {
  local dev="$1" sg_dev="$2"
  local year="N/A" written="N/A" poh=""

  if smartctl -i "$dev" &>/dev/null; then
    year_smart=$(smartctl -i "$dev" | grep -Ei 'manufacture|date' | grep -oE '[0-9]{4}' | head -n1 || true)
    if [[ -z "$year_smart" ]]; then
      poh=$(smartctl -A "$dev" 2>/dev/null | grep -i 'Power_On_Hours' | grep -oE '[0-9]+$' | head -n1 || true)
    else
      year="$year_smart"
    fi
  fi

  if [[ "$sg_dev" =~ ^/dev/sg[0-9]+$ ]]; then
    smart_output=$(timeout 5 "$OPENSEA_SMART" -d "$sg_dev" -i 2>/dev/null)

    # Manufacture Year
    year_os=$(echo "$smart_output" | grep -i 'Date Of Manufacture' | grep -oE '[0-9]{4}' | head -n1 || true)

    # Bytes Written
    written_os=$(echo "$smart_output" | grep -i 'Total Bytes Written (TB)' | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)

    # Power on hours
    poh_os=$(echo "$smart_output" | grep -i 'Power On Hours' | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)

    [[ "$year" == "N/A" && -n "$year_os" ]] && year="$year_os"
    [[ -z "$poh" && -n "$poh_os" ]] && poh="$poh_os"
    [[ -n "$written_os" ]] && written="$written_os TB"
  fi

  if [[ "$year" == "N/A" && -n "$poh" ]]; then
    local current_year=$(date +%Y)
    local poh_int=${poh%.*}
    local est_year=$(( current_year - poh_int / 8760 ))
    year="$est_year (est.)"
  fi

  echo "$year|$written"
}

print_header() {
  printf "%-60s %-6s %-10s %-24s %-22s %-10s %-10s %-10s %-12s %-12s\n" \
    "Device" "Size" "Vendor" "Model" "Serial" "/dev/sdX" "/dev/sgX" "STATE" "Year" "Written"
  printf "%s\n" "$(printf '%.0s-' {1..186})"
}

print_device_info() {
  local partuuid_dev="$1"
  local state="${DEV_STATES[$partuuid_dev]:-UNUSED}"

  local sd_dev sg_dev vendor model serial year written size
  [[ "$partuuid_dev" =~ ^/dev/sd[a-z]+$ ]] && sd_dev="$partuuid_dev" || sd_dev=$(resolve_sd "$partuuid_dev")
  sg_dev=$(resolve_sg "$sd_dev")
  IFS="|" read -r vendor model serial <<< "$(get_disk_info "$sd_dev")"
  IFS="|" read -r year written <<< "$(get_year_and_written "$sd_dev" "$sg_dev")"
  size=$(lsblk "$partuuid_dev" -o SIZE -dn 2>/dev/null || echo "N/A")

  local fmt="%-60s %-6s %-10s %-24s %-22s %-10s %-10s %-10s %-12s %-12s\n"
  [[ "$state" == "FAULTED" ]] && printf "\033[31m$fmt\033[0m" \
    "$partuuid_dev" "$size" "${vendor:-N/A}" "${model:-N/A}" "${serial:-N/A}" "$sd_dev" "$sg_dev" "$state" "$year" "$written" \
    || printf "$fmt" \
    "$partuuid_dev" "$size" "${vendor:-N/A}" "${model:-N/A}" "${serial:-N/A}" "$sd_dev" "$sg_dev" "$state" "$year" "$written"
}

[[ "${1:-}" == "--all" ]] && pools=$(zpool list -H -o name) || pools="$1"
print_header
declare -A seen used_sd_parents

for pool in $pools; do
  echo "Pool: $pool"
  get_device_states_for_pool "$pool"
  for dev in $(get_devices_for_pool "$pool"); do
    parent=$(lsblk -no PKNAME "$dev" 2>/dev/null || true)
    [[ -n "$parent" ]] && used_sd_parents["/dev/$parent"]=1
    [[ -z "${seen[$dev]+x}" ]] && print_device_info "$dev" && seen[$dev]=1
  done
  echo
done

echo "Unassigned Devices:"
print_header
for dev_path in /dev/sd?; do
  [[ -n "${used_sd_parents[$dev_path]+x}" ]] && continue
  print_device_info "$dev_path"
done
