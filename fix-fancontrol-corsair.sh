#!/bin/bash
set -euo pipefail

###############################################################################
# fix-fancontrol-corsair.sh
#
# This script verifies and optionally fixes the /etc/fancontrol configuration
# for a Corsair Commander (or similar) USB fan controller.
#
# What it does:
#  1. Finds the current hwmonX label assigned to the Corsair device in /sys
#  2. Extracts the assigned hwmonX label and USB device path from /etc/fancontrol
#  3. Compares both the hwmon label and the USB device path between /sys and fancontrol
#  4. If mismatches are found:
#     - In dry run (default): shows which lines would be changed
#     - With --apply: safely updates all affected lines and makes a backup
#
# Usage:
#   ./fix-fancontrol-corsair.sh         # dry run, shows what would change
#   ./fix-fancontrol-corsair.sh --apply # apply fixes in-place
#
# Author: ChatGPT (for Warren Hughes)
###############################################################################

FANCONTROL_FILE="/etc/fancontrol"
BACKUP_FILE="/etc/fancontrol.bak.$(date +%s)"
APPLY=0

if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
  echo "[INFO] Live update mode enabled. Will apply changes."
else
  echo "[INFO] Dry run mode. No changes will be made. Use '--apply' to update."
fi

# Step 1: Find actual hwmonX and sysfs path for corsair
CURRENT_HWMON=""
CURRENT_DEVICE_PATH=""
for h in /sys/class/hwmon/hwmon*/name; do
  if grep -qi 'corsair' "$h"; then
    CURRENT_HWMON=$(basename "$(dirname "$h")")
    CURRENT_DEVICE_PATH=$(readlink -f "$(dirname "$h")" | sed 's|^/sys/||' | sed 's|/hwmon/.*||')
    break
  fi
done

if [[ -z "$CURRENT_HWMON" || -z "$CURRENT_DEVICE_PATH" ]]; then
  echo "[ERROR] Could not find a hwmon device with name containing 'corsair'"
  exit 1
fi

echo "[INFO] Detected corsair device in /sys as:"
echo "        hwmon label : $CURRENT_HWMON"
echo "        device path : devices/$CURRENT_DEVICE_PATH"

# Step 2: Extract hwmonX and device path from fancontrol
CONFIGURED_HWMON=$(awk -F'[= ]' '/^DEVNAME=/ && $2 ~ /^hwmon[0-9]+$/ && $3 ~ /corsair/ { print $2 }' "$FANCONTROL_FILE")
CONFIGURED_DEVPATH=$(grep "^DEVPATH=$CONFIGURED_HWMON=" "$FANCONTROL_FILE" | cut -d= -f3)

if [[ -z "$CONFIGURED_HWMON" || -z "$CONFIGURED_DEVPATH" ]]; then
  echo "[ERROR] Could not find both DEVNAME and DEVPATH for corsaircpro in /etc/fancontrol"
  exit 1
fi

echo "[INFO] fancontrol assigns 'corsaircpro' as:"
echo "        hwmon label : $CONFIGURED_HWMON"
echo "        device path : devices/$CONFIGURED_DEVPATH"

# Step 3: Compare and report
LABEL_MATCH=0
PATH_MATCH=0
[[ "$CURRENT_HWMON" == "$CONFIGURED_HWMON" ]] && LABEL_MATCH=1
[[ "$CURRENT_DEVICE_PATH" == "$CONFIGURED_DEVPATH" ]] && PATH_MATCH=1

if [[ $LABEL_MATCH -eq 1 && $PATH_MATCH -eq 1 ]]; then
  echo "[SUCCESS] /etc/fancontrol is already correct."
  echo "[EVIDENCE] hwmon label and device path match system state."
  exit 0
fi

# Step 4: Describe what needs changing
if [[ $LABEL_MATCH -eq 0 ]]; then
  echo "[MISMATCH] hwmon label:"
  echo "    → fancontrol uses: $CONFIGURED_HWMON"
  echo "    → sysfs reports : $CURRENT_HWMON"
fi

if [[ $PATH_MATCH -eq 0 ]]; then
  echo "[MISMATCH] device path:"
  echo "    → fancontrol uses: devices/$CONFIGURED_DEVPATH"
  echo "    → sysfs reports : devices/$CURRENT_DEVICE_PATH"
fi

echo "[INFO] Preparing to update all instances of $CONFIGURED_HWMON and its path..."

TMP_FILE=$(mktemp)
CHANGES_MADE=0

while IFS= read -r line || [[ -n "$line" ]]; do
  NEW_LINE="$line"

  # Replace hwmon label if needed
  if [[ $LABEL_MATCH -eq 0 && "$NEW_LINE" == *"$CONFIGURED_HWMON"* ]]; then
    NEW_LINE="${NEW_LINE//$CONFIGURED_HWMON/$CURRENT_HWMON}"
    CHANGES_MADE=1
  fi

  # Replace device path if needed
  if [[ $PATH_MATCH -eq 0 && "$NEW_LINE" == *"$CONFIGURED_DEVPATH"* ]]; then
    NEW_LINE="${NEW_LINE//$CONFIGURED_DEVPATH/$CURRENT_DEVICE_PATH}"
    CHANGES_MADE=1
  fi

  if [[ "$line" != "$NEW_LINE" ]]; then
    if [[ "$APPLY" -eq 1 ]]; then
      echo "$NEW_LINE" >> "$TMP_FILE"
    else
      echo "[DRY RUN] Would update:"
      echo "    OLD: $line"
      echo "    NEW: $NEW_LINE"
    fi
  else
    echo "$line" >> "$TMP_FILE"
  fi
done < "$FANCONTROL_FILE"

# Step 5: Apply if required
if [[ "$CHANGES_MADE" -eq 1 && "$APPLY" -eq 1 ]]; then
  echo "[INFO] Backing up to $BACKUP_FILE"
  cp "$FANCONTROL_FILE" "$BACKUP_FILE"
  mv "$TMP_FILE" "$FANCONTROL_FILE"
  echo "[SUCCESS] fancontrol updated successfully."
elif [[ "$CHANGES_MADE" -eq 1 ]]; then
  rm -f "$TMP_FILE"
  echo "[INFO] Dry run complete. Use '--apply' to make these changes."
else
  rm -f "$TMP_FILE"
  echo "[INFO] No changes were needed."
fi
