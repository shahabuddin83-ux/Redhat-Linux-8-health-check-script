#!/bin/bash
# =============================================================================
# RHEL 8 System Health Check Script
# Compatible with: Red Hat Enterprise Linux 8.x
# Usage: bash rhel8_healthcheck.sh [--report /path/to/report.txt]
# =============================================================================

# ---------- Color Codes ----------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------- Thresholds ----------
CPU_WARN=70       # % usage warning
CPU_CRIT=90       # % usage critical
RAM_WARN=75
RAM_CRIT=90
SWAP_WARN=50
SWAP_CRIT=80
DISK_WARN=75
DISK_CRIT=90
LOAD_WARN=2.0     # load average per core warn multiplier
LOAD_CRIT=4.0

# ---------- Report File ----------
REPORT_FILE=""
if [[ "$1" == "--report" && -n "$2" ]]; then
    REPORT_FILE="$2"
fi

# ---------- Helpers ----------
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

log() {
    echo -e "$*"
    [[ -n "$REPORT_FILE" ]] && echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$REPORT_FILE"
}

section() {
    log ""
    log "${CYAN}${BOLD}══════════════════════════════════════════════════${RESET}"
    log "${CYAN}${BOLD}  $1${RESET}"
    log "${CYAN}${BOLD}══════════════════════════════════════════════════${RESET}"
}

status_ok()   { log "  ${GREEN}[PASS]${RESET} $*"; ((PASS_COUNT++)); }
status_warn() { log "  ${YELLOW}[WARN]${RESET} $*"; ((WARN_COUNT++)); }
status_fail() { log "  ${RED}[FAIL]${RESET} $*"; ((FAIL_COUNT++)); }
status_info() { log "  ${CYAN}[INFO]${RESET} $*"; }

compare() {
    local label="$1" value="$2" warn="$3" crit="$4" unit="$5"
    if (( $(echo "$value >= $crit" | bc -l) )); then
        status_fail "$label: ${value}${unit} (threshold: critical >=${crit}${unit})"
    elif (( $(echo "$value >= $warn" | bc -l) )); then
        status_warn "$label: ${value}${unit} (threshold: warning >=${warn}${unit})"
    else
        status_ok  "$label: ${value}${unit} (OK)"
    fi
}

# =============================================================================
# HEADER
# =============================================================================
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOSTNAME=$(hostname -f 2>/dev/null || hostname)

[[ -n "$REPORT_FILE" ]] && > "$REPORT_FILE"

log ""
log "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
log "${BOLD}║       RHEL 8 System Health Check Report          ║${RESET}"
log "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
log "  Host      : ${BOLD}${HOSTNAME}${RESET}"
log "  Timestamp : ${TIMESTAMP}"
log "  Run as    : $(whoami)"

# =============================================================================
# 1. OS & KERNEL
# =============================================================================
section "1. OS & KERNEL INFORMATION"

if [[ -f /etc/redhat-release ]]; then
    OS_VER=$(cat /etc/redhat-release)
    status_info "OS Release : $OS_VER"
else
    status_warn "Cannot read /etc/redhat-release"
fi

KERNEL=$(uname -r)
status_info "Kernel     : $KERNEL"
status_info "Architecture: $(uname -m)"
status_info "Uptime     : $(uptime -p 2>/dev/null || uptime)"

# =============================================================================
# 2. CPU
# =============================================================================
section "2. CPU HEALTH"

CPU_CORES=$(nproc --all)
status_info "CPU Cores (logical): $CPU_CORES"

CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | awk -F': ' '{print $2}')
status_info "CPU Model: $CPU_MODEL"

# Current CPU usage (1-second sample using /proc/stat)
read -r cpu user nice system idle iowait irq softirq steal _ < <(grep '^cpu ' /proc/stat)
sleep 1
read -r cpu2 user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 _ < <(grep '^cpu ' /proc/stat)

total1=$(( user + nice + system + idle + iowait + irq + softirq + steal ))
total2=$(( user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2 ))
idle_diff=$(( idle2 - idle ))
total_diff=$(( total2 - total1 ))

if (( total_diff > 0 )); then
    CPU_USAGE=$(echo "scale=1; (1 - $idle_diff / $total_diff) * 100" | bc)
else
    CPU_USAGE=0
fi

compare "CPU Usage" "$CPU_USAGE" "$CPU_WARN" "$CPU_CRIT" "%"

# iowait
IOWAIT=$(echo "scale=1; ($iowait2 - $iowait) * 100 / $total_diff" | bc 2>/dev/null || echo "0")
compare "CPU I/O Wait" "$IOWAIT" "15" "30" "%"

# Load average
LOAD1=$(awk '{print $1}' /proc/loadavg)
LOAD5=$(awk '{print $2}' /proc/loadavg)
LOAD15=$(awk '{print $3}' /proc/loadavg)
status_info "Load Average (1/5/15 min): $LOAD1 / $LOAD5 / $LOAD15"

LOAD_WARN_ABS=$(echo "$LOAD_WARN * $CPU_CORES" | bc)
LOAD_CRIT_ABS=$(echo "$LOAD_CRIT * $CPU_CORES" | bc)
compare "Load Avg (1 min) vs Cores" "$LOAD1" "$LOAD_WARN_ABS" "$LOAD_CRIT_ABS" ""

# =============================================================================
# 3. RAM (MEMORY)
# =============================================================================
section "3. RAM / MEMORY HEALTH"

MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
MEM_USED=$(( MEM_TOTAL - MEM_AVAIL ))
MEM_USAGE_PCT=$(echo "scale=1; $MEM_USED * 100 / $MEM_TOTAL" | bc)

MEM_TOTAL_GB=$(echo "scale=2; $MEM_TOTAL / 1048576" | bc)
MEM_USED_GB=$(echo "scale=2; $MEM_USED / 1048576" | bc)
MEM_AVAIL_GB=$(echo "scale=2; $MEM_AVAIL / 1048576" | bc)

status_info "Total RAM   : ${MEM_TOTAL_GB} GB"
status_info "Used RAM    : ${MEM_USED_GB} GB"
status_info "Available   : ${MEM_AVAIL_GB} GB"

compare "RAM Usage" "$MEM_USAGE_PCT" "$RAM_WARN" "$RAM_CRIT" "%"

# Buffers & Cache
BUFFERS=$(grep Buffers /proc/meminfo | awk '{print $2}')
CACHED=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
BUFCACHE_GB=$(echo "scale=2; ($BUFFERS + $CACHED) / 1048576" | bc)
status_info "Buffers + Cache: ${BUFCACHE_GB} GB"

# =============================================================================
# 4. SWAP MEMORY
# =============================================================================
section "4. SWAP MEMORY HEALTH"

SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
SWAP_FREE=$(grep SwapFree /proc/meminfo | awk '{print $2}')
SWAP_USED=$(( SWAP_TOTAL - SWAP_FREE ))

if (( SWAP_TOTAL == 0 )); then
    status_warn "No swap space configured (consider adding swap for RHEL 8)"
else
    SWAP_TOTAL_GB=$(echo "scale=2; $SWAP_TOTAL / 1048576" | bc)
    SWAP_USED_GB=$(echo "scale=2; $SWAP_USED / 1048576" | bc)
    SWAP_FREE_GB=$(echo "scale=2; $SWAP_FREE / 1048576" | bc)
    SWAP_PCT=$(echo "scale=1; $SWAP_USED * 100 / $SWAP_TOTAL" | bc)

    status_info "Total Swap  : ${SWAP_TOTAL_GB} GB"
    status_info "Used Swap   : ${SWAP_USED_GB} GB"
    status_info "Free Swap   : ${SWAP_FREE_GB} GB"
    compare "Swap Usage" "$SWAP_PCT" "$SWAP_WARN" "$SWAP_CRIT" "%"
fi

# swappiness
SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "N/A")
status_info "vm.swappiness: $SWAPPINESS"
if [[ "$SWAPPINESS" != "N/A" ]] && (( SWAPPINESS > 60 )); then
    status_warn "vm.swappiness=$SWAPPINESS is high; consider 10-30 for servers"
else
    status_ok "vm.swappiness=$SWAPPINESS (acceptable)"
fi

# =============================================================================
# 5. DISK / HARD DISK HEALTH
# =============================================================================
section "5. DISK / HARD DISK HEALTH"

# Disk space per filesystem
status_info "Filesystem Usage:"
log ""
log "  $(df -h --output=source,fstype,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x overlay | head -1)"
log "  $(df -h --output=source,fstype,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x overlay | tail -n +2)"
log ""

while read -r src fstype size used avail pct target; do
    pct_num=${pct//%/}
    compare "Disk [$target] ($src)" "$pct_num" "$DISK_WARN" "$DISK_CRIT" "%"
done < <(df --output=source,fstype,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x overlay | tail -n +2 | awk '{print $1,$2,$3,$4,$5,$6,$7}')

# inode usage
status_info ""
status_info "Inode Usage:"
while read -r src inodes iused ifree ipct target; do
    ipct_num=${ipct//%/}
    [[ "$ipct_num" =~ ^[0-9]+$ ]] && compare "Inodes [$target]" "$ipct_num" "75" "90" "%"
done < <(df -i --output=source,itotal,iused,iavail,ipcent,target -x tmpfs -x devtmpfs | tail -n +2)

# Physical disk info (lsblk)
status_info ""
status_info "Block Devices:"
lsblk -o NAME,TYPE,SIZE,ROTA,MOUNTPOINT,MODEL 2>/dev/null | while read -r line; do
    status_info "$line"
done

# Disk I/O stats (requires iostat from sysstat)
if command -v iostat &>/dev/null; then
    status_info ""
    status_info "Disk I/O Snapshot (1 sec):"
    iostat -dx 1 2 2>/dev/null | tail -n +7 | head -20 | while read -r line; do
        [[ -n "$line" ]] && status_info "$line"
    done
else
    status_warn "iostat not found — install 'sysstat' for disk I/O stats (dnf install sysstat)"
fi

# =============================================================================
# 6. FILESYSTEM CHECKS
# =============================================================================
section "6. FILESYSTEM HEALTH"

# Mounted filesystems
status_info "Mounted Filesystems:"
while read -r line; do
    status_info "$line"
done < <(mount | grep -E 'ext4|xfs|btrfs|nfs|cifs' | awk '{print $1, $3, $5}')

# Read-only check
RO_FS=$(grep ' ro,' /proc/mounts | grep -v -E 'proc|sys|dev|run|boot/efi' | awk '{print $2}' | tr '\n' ' ')
if [[ -n "$RO_FS" ]]; then
    status_warn "Read-only filesystems detected: $RO_FS"
else
    status_ok "No unexpected read-only filesystems found"
fi

# Check /tmp writability
if touch /tmp/.healthcheck_test 2>/dev/null; then
    rm -f /tmp/.healthcheck_test
    status_ok "/tmp is writable"
else
    status_fail "/tmp is NOT writable"
fi

# XFS filesystem check (RHEL 8 default)
if command -v xfs_info &>/dev/null; then
    XFS_MOUNTS=$(df -T | awk '$2=="xfs"{print $1}')
    for dev in $XFS_MOUNTS; do
        status_info "XFS info for $dev:"
        xfs_info "$dev" 2>/dev/null | grep -E 'data|log|meta' | while read -r l; do status_info "  $l"; done
    done
fi

# =============================================================================
# 7. NETWORK INTERFACES
# =============================================================================
section "7. NETWORK INTERFACES"

if command -v ip &>/dev/null; then
    while read -r iface state; do
        if [[ "$state" == "UP" ]]; then
            status_ok "Interface $iface is UP"
        else
            status_warn "Interface $iface is $state"
        fi
    done < <(ip -br link show | awk '{print $1, $2}' | grep -v '^lo')

    status_info ""
    status_info "IP Addresses:"
    ip -br addr show | while read -r line; do status_info "$line"; done
fi

# =============================================================================
# 8. SYSTEM SERVICES (CRITICAL)
# =============================================================================
section "8. CRITICAL SYSTEM SERVICES"

CRITICAL_SERVICES=("sshd" "chronyd" "firewalld" "rsyslog" "NetworkManager" "auditd" "crond")

for svc in "${CRITICAL_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        status_ok "Service '$svc' is active"
    elif systemctl list-unit-files --quiet "$svc.service" &>/dev/null; then
        status_warn "Service '$svc' is NOT running"
    else
        status_info "Service '$svc' not installed (skipping)"
    fi
done

# Failed services
FAILED_SVCS=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [[ -n "$FAILED_SVCS" ]]; then
    status_fail "Failed services detected: $FAILED_SVCS"
else
    status_ok "No failed systemd services"
fi

# =============================================================================
# 9. OPEN FILES & LIMITS
# =============================================================================
section "9. OPEN FILES & SYSTEM LIMITS"

OPEN_FILES=$(lsof 2>/dev/null | wc -l || ls /proc/*/fd 2>/dev/null | wc -l)
status_info "Approximate open file descriptors: $OPEN_FILES"

FILE_MAX=$(cat /proc/sys/fs/file-max)
FILE_NR=$(awk '{print $1}' /proc/sys/fs/file-nr)
status_info "System file-max limit : $FILE_MAX"
status_info "Currently allocated   : $FILE_NR"

# Check ulimits
status_info "Current user ulimits (nofile): $(ulimit -n)"
if (( $(ulimit -n) < 4096 )); then
    status_warn "Open file limit (ulimit -n) is low: $(ulimit -n)"
else
    status_ok "Open file limit: $(ulimit -n)"
fi

# =============================================================================
# 10. SECURITY & UPDATES
# =============================================================================
section "10. SECURITY & UPDATES"

# SELinux
SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Not installed")
if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
    status_ok "SELinux is Enforcing"
elif [[ "$SELINUX_STATUS" == "Permissive" ]]; then
    status_warn "SELinux is Permissive (not enforcing)"
else
    status_fail "SELinux is Disabled or not installed"
fi

# Firewalld
if systemctl is-active --quiet firewalld 2>/dev/null; then
    status_ok "firewalld is active"
else
    status_warn "firewalld is not running"
fi

# Pending updates
if command -v dnf &>/dev/null; then
    UPDATE_COUNT=$(dnf check-update --quiet 2>/dev/null | grep -c '^[a-zA-Z]' || echo "0")
    if (( UPDATE_COUNT > 0 )); then
        status_warn "Pending package updates: $UPDATE_COUNT"
    else
        status_ok "System is up to date (or cannot check)"
    fi
fi

# Last login info
status_info "Last 3 logins:"
last -n 3 2>/dev/null | while read -r line; do status_info "  $line"; done

# =============================================================================
# 11. DMESG ERRORS (recent)
# =============================================================================
section "11. RECENT KERNEL ERRORS (dmesg)"

DMESG_ERRORS=$(dmesg --level=err,crit,emerg 2>/dev/null | tail -10)
if [[ -n "$DMESG_ERRORS" ]]; then
    status_warn "Recent kernel errors found:"
    echo "$DMESG_ERRORS" | while read -r line; do
        log "  ${RED}$line${RESET}"
    done
else
    status_ok "No critical kernel errors in dmesg"
fi

# =============================================================================
# SUMMARY
# =============================================================================
section "HEALTH CHECK SUMMARY"

TOTAL=$(( PASS_COUNT + WARN_COUNT + FAIL_COUNT ))

log "  ${GREEN}PASSED${RESET}  : $PASS_COUNT"
log "  ${YELLOW}WARNINGS${RESET}: $WARN_COUNT"
log "  ${RED}FAILED${RESET}  : $FAIL_COUNT"
log "  Total Checks : $TOTAL"
log ""

if (( FAIL_COUNT > 0 )); then
    log "  ${RED}${BOLD}Overall Status: CRITICAL — Immediate attention required!${RESET}"
elif (( WARN_COUNT > 0 )); then
    log "  ${YELLOW}${BOLD}Overall Status: WARNING — Review flagged items.${RESET}"
else
    log "  ${GREEN}${BOLD}Overall Status: HEALTHY — All checks passed.${RESET}"
fi

log ""
log "  Report generated: $TIMESTAMP"
[[ -n "$REPORT_FILE" ]] && log "  Saved to: $REPORT_FILE"
log ""
