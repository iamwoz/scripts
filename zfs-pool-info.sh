#!/bin/bash

set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "[USAGE] $0 <pool-name> | --all"
  echo "         Show ZFS pool device information using smartctl and openSeaChest."
  exit 1
fi

OPENSEA_CACHE_DIR="${HOME}/.cache/openseachest"
OPENSEA_SMART="${OPENSEA_CACHE_DIR}/openSeaChest_SMART"
VERSION_FILE="${OPENSEA_CACHE_DIR}/version.txt"

echo "[INFO] Checking openSeaChest_SMART availability..."

download_openseachest() {
  echo "[INFO] Downloading latest openSeaChest portable release..."

  mkdir -p "$OPENSEA_CACHE_DIR"
  tmpfile=$(mktemp)

  remote_ver=$(curl -s https://api.github.com/repos/Seagate/openSeaChest/releases/latest | jq -r '.tag_name' | sed 's/^v//')
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

  echo "$remote_ver" > "$VERSION_FILE"
  echo "[INFO] openSeaChest_SMART updated to version $remote_ver."
}

remote_ver=$(curl -s https://api.github.com/repos/Seagate/openSeaChest/releases/latest | jq -r '.tag_name' | sed 's/^v//')
current_ver=$(cat "$VERSION_FILE" 2>/dev/null || echo "")

if [[ "$remote_ver" != "$current_ver" || ! -x "$OPENSEA_SMART" ]]; then
  echo "[INFO] New openSeaChest release detected or not cached (cached: ${current_ver:-none}, latest: $remote_ver), updating..."
  download_openseachest
else
  echo "[INFO] openSeaChest_SMART is up-to-date (cached release: $current_ver)."
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

    year_os=$(echo "$smart_output" | grep -i 'Date Of Manufacture' | grep -oE '[0-9]{4}' | head -n1 || true)
    written_os=$(echo "$smart_output" | grep -i 'Total Bytes Written (TB)' | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)
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
  printf "%-36s %-6s %-10s %-24s %-22s %-10s %-10s %-10s %-12s %-12s %-4s\n" \
    "Device" "Size" "Vendor" "Model" "Serial" "/dev/sdX" "/dev/sgX" "STATE" "Year" "Written" "Type"
  printf "%s\n" "$(printf '%.0s-' {1..171})"
}

print_device_info() {
  local path="$1"
  local state="${DEV_STATES[$path]:-UNUSED}"
  local sd_dev sg_dev vendor model serial year written size dev_label

  [[ "$path" =~ ^/dev/sd[a-z]+$ ]] && sd_dev="$path" || sd_dev=$(resolve_sd "$path")
  sg_dev=$(resolve_sg "$sd_dev")

  IFS="|" read -r vendor model serial <<< "$(get_disk_info "$sd_dev")"
  IFS="|" read -r year written <<< "$(get_year_and_written "$sd_dev" "$sg_dev")"
  size=$(lsblk "$path" -o SIZE -dn 2>/dev/null || echo "N/A")

  if [[ "$state" == "UNUSED" ]]; then
    dev_label="$sd_dev"
  else
    partuuid=$(blkid -s PARTUUID -o value "$path" 2>/dev/null || echo "")
    dev_label="$partuuid"
  fi

  local smr="NO"
  if smartctl -i "$sd_dev" 2>/dev/null | grep -i '^Model Family:' | grep -q 'SMR'; then
    smr="YES"
  fi

  local fmt="%-36s %-6s %-10s %-24s %-22s %-10s %-10s %-10s %-12s %-12s %-4s\n"

  if [[ "$smr" == "YES" ]]; then
    printf "\033[31m$fmt\033[0m" \
      "$dev_label" "$size" "${vendor:-N/A}" "${model:-N/A}" "${serial:-N/A}" \
      "$sd_dev" "$sg_dev" "$state" "$year" "$written" "$smr"
  else
    printf "$fmt" \
      "$dev_label" "$size" "${vendor:-N/A}" "${model:-N/A}" "${serial:-N/A}" \
      "$sd_dev" "$sg_dev" "$state" "$year" "$written" "$smr"
  fi
}

[[ "$1" == "--all" ]] && pools=$(zpool list -H -o name) || pools="$1"
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
