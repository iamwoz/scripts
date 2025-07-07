#!/bin/bash

# reboot_cause_report.sh
# Reports recent reboots, their causes, uptimes, and summary frequency

NUM_REBOOTS=20
LOG_LINES=1000

# ANSI colors
RED="\e[31m"
RESET="\e[0m"

# Disable pager for journalctl
export PAGER=cat

echo "Analyzing the last $NUM_REBOOTS reboots..."
echo

# Tracking for summary
total=0
user_count=0
crash_count=0
likely_crash_count=0
power_loss_count=0
unknown_count=0
first_timestamp=""
last_timestamp=""

for ((i=NUM_REBOOTS-1; i>=0; i--)); do
    BOOT_IDX="-$i"
    NEXT_IDX="-$((i - 1))"
    PREV_IDX="-$((i + 1))"

    echo "------------------------------------------------------------"

    # Check if current boot exists
    if ! journalctl -b "$BOOT_IDX" -n 1 &>/dev/null; then
        echo -e "⚠️  Skipping boot $BOOT_IDX — journal data unavailable"
        continue
    fi

    # Get timestamp of reboot
    FIRST_LINE=$(journalctl -b "$BOOT_IDX" -n 1 | head -n 1)
    BOOT_TIME=$(echo "$FIRST_LINE" | cut -d' ' -f1-3)
    BOOT_TIMESTAMP=$(date --date="$BOOT_TIME" +%s 2>/dev/null)

    if [[ -z "$first_timestamp" ]]; then
        first_timestamp="$BOOT_TIMESTAMP"
    fi
    last_timestamp="$BOOT_TIMESTAMP"

    # Get kernel version (fast and reliable)
    KERNEL_LINE=$(journalctl -b "$BOOT_IDX" -k | grep -m1 'Linux version')
    KERNEL_VER=$(echo "$KERNEL_LINE" | grep -oP 'Linux version \K\S+')
    [ -z "$KERNEL_VER" ] && KERNEL_VER="(unknown)"

    echo "🕒 Reboot Time: $BOOT_TIME | Kernel: $KERNEL_VER"

    # Estimate uptime using the next boot's start time
    if journalctl -b "$NEXT_IDX" -n 1 &>/dev/null; then
        NEXT_LINE=$(journalctl -b "$NEXT_IDX" -n 1 | head -n 1)
        NEXT_TIME=$(echo "$NEXT_LINE" | cut -d' ' -f1-3)
        NEXT_TIMESTAMP=$(date --date="$NEXT_TIME" +%s 2>/dev/null)

        if [[ -n "$BOOT_TIMESTAMP" && -n "$NEXT_TIMESTAMP" && "$NEXT_TIMESTAMP" -gt "$BOOT_TIMESTAMP" ]]; then
            SECONDS_UP=$((NEXT_TIMESTAMP - BOOT_TIMESTAMP))
            DAYS=$((SECONDS_UP / 86400))
            HOURS=$(( (SECONDS_UP % 86400) / 3600 ))
            MINS=$(( (SECONDS_UP % 3600) / 60 ))
            echo "⏱  Uptime: ${DAYS}d ${HOURS}h ${MINS}m"
        fi
    fi

    # Determine cause of reboot
    if ! journalctl -b "$PREV_IDX" -n 1 &>/dev/null; then
        echo -e "🔍 Cause: ${RED}POWER-LOSS (no logs from previous boot)${RESET}"
        ((power_loss_count++))
    else
        PREV_LOGS=$(journalctl -b "$PREV_IDX" -n "$LOG_LINES")

        if grep -qiE 'sudo.*(reboot|shutdown|poweroff)' <<< "$PREV_LOGS"; then
            echo "🔍 Cause: USER-INITIATED (via sudo command)"
            ((user_count++))
        elif grep -qiE 'systemd.*(reboot|shutdown|poweroff)' <<< "$PREV_LOGS"; then
            echo "🔍 Cause: USER-INITIATED (graceful system shutdown)"
            ((user_count++))
        elif grep -qiE 'BUG:|Oops:|segfault|Call Trace|tainted|not syncing' <<< "$PREV_LOGS"; then
            echo -e "🔍 Cause: ${RED}CRASH (kernel panic or critical error)${RESET}"
            ((crash_count++))
        elif ! tail -n 20 <<< "$PREV_LOGS" | grep -qiE 'reached target|systemd-shutdown|stopped target|shutting down'; then
            echo -e "🔍 Cause: ${RED}LIKELY CRASH (abrupt log end without shutdown)${RESET}"
            ((likely_crash_count++))
        else
            echo -e "🔍 Cause: ${RED}UNKNOWN (could not determine)${RESET}"
            ((unknown_count++))
        fi
    fi

    ((total++))
done

# Duration
if [[ -n "$first_timestamp" && -n "$last_timestamp" ]]; then
    SECONDS_RANGE=$((last_timestamp - first_timestamp))
    DAYS_RANGE=$(awk "BEGIN {printf \"%.1f\", $SECONDS_RANGE / 86400}")
else
    DAYS_RANGE="(unknown)"
fi

# Crash stats
total_crashes=$((crash_count + likely_crash_count))

if [[ "$DAYS_RANGE" != "(unknown)" && "$DAYS_RANGE" != "0.0" ]]; then
    REBOOTS_PER_WEEK=$(awk "BEGIN {printf \"%.2f\", $total / $DAYS_RANGE * 7}")
    REBOOTS_PER_MONTH=$(awk "BEGIN {printf \"%.2f\", $total / $DAYS_RANGE * 30.4375}")
    CRASHES_PER_WEEK=$(awk "BEGIN {printf \"%.2f\", $total_crashes / $DAYS_RANGE * 7}")
    CRASHES_PER_MONTH=$(awk "BEGIN {printf \"%.2f\", $total_crashes / $DAYS_RANGE * 30.4375}")
    DAYS_PER_CRASH=$(awk "BEGIN {printf \"%.1f\", $DAYS_RANGE / ($total_crashes == 0 ? 1 : $total_crashes)}")
else
    REBOOTS_PER_WEEK="(unknown)"
    CRASHES_PER_WEEK="(unknown)"
    REBOOTS_PER_MONTH="(unknown)"
    CRASHES_PER_MONTH="(unknown)"
    DAYS_PER_CRASH="(unknown)"
fi

# Summary
echo ""
echo "=============== REBOOT SUMMARY ==============="
echo "🔁 Total reboots analyzed : $total"
echo "✅ User-initiated         : $user_count"
echo "💥 Crashes                : $crash_count"
echo "❗ Likely crashes         : $likely_crash_count"
echo "⚡ Power loss             : $power_loss_count"
echo "❓ Unknown causes         : $unknown_count"
echo ""
echo "📆 Days covered           : $DAYS_RANGE"
echo "📊 Reboots/week           : $REBOOTS_PER_WEEK"
echo "📊 Reboots/month          : $REBOOTS_PER_MONTH"
echo "💣 Crashes/week           : $CRASHES_PER_WEEK"
echo "💣 Crashes/month          : $CRASHES_PER_MONTH"
echo "⏱  Avg days per crash     : $DAYS_PER_CRASH"
echo "=============================================="
