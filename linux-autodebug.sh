#!/usr/bin/env bash
# Linux Auto-Debug + Self-Heal
# Works on Ubuntu/Debian & RHEL/Alma/Rocky
# Default: read-only checks. Use --apply to perform safe remediations.

set -euo pipefail

APPLY=false
AGGRESSIVE=false
REPORT=""
START_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --aggressive) AGGRESSIVE=true ;;
    --report) REPORT="${2:-}"; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: linux-autodebug.sh [--apply] [--aggressive] [--report <file>]
  --apply       Perform safe remediations (journals vacuum, logrotate, restart failed services,
                fix DNS fallback, clear pkg caches, time sync)
  --aggressive  Also restart processes holding deleted files (may bounce daemons)
  --report      Save a full report to this path
EOF
      exit 0
      ;;
  esac
  shift
done

# tee to report if requested
if [[ -n "$REPORT" ]]; then
  exec > >(tee -a "$REPORT") 2>&1
fi

log() { echo "[$(date +'%H:%M:%S')] $*"; }
hr()  { printf -- "----------------------------------------------\n"; }
need_root() { if [[ "$APPLY" == true && $EUID -ne 0 ]]; then echo "Please run with sudo for --apply"; exit 1; fi; }
run_safe() { bash -c "$1" || log "WARN: '$1' failed (continuing)"; }

# ===============================
# Final Summary - function
# ===============================
final_summary() {
  echo
  echo "============================================================"
  echo "[Final Summary - Plain English]"

  # System Load (no bc dependency)
  LOAD=$(uptime | awk -F'load average: ' '{print $2}' | cut -d, -f1 | tr -d ' ')
  if awk "BEGIN {exit !($LOAD > 2.0)}"; then
    echo "- ⚠️ System load is high ($LOAD). Investigate CPU-intensive processes."
  else
    echo "- ✅ System load is normal ($LOAD)."
  fi

  # Memory
  AVAIL=$(free -m | awk '/Mem:/ {print $7}')
  if [ -n "$AVAIL" ] && [ "$AVAIL" -lt 200 ]; then
    echo "- ⚠️ Low memory available (${AVAIL}MB). Consider adding RAM or stopping apps."
  else
    echo "- ✅ Memory is healthy (${AVAIL:-unknown}MB available)."
  fi

  # Disk
  ROOTUSE=$(df --output=pcent / | tail -1 | tr -dc '0-9')
  if [ -n "$ROOTUSE" ] && [ "$ROOTUSE" -gt 85 ]; then
    echo "- ⚠️ Root filesystem is ${ROOTUSE}% full. Free up space soon."
  else
    echo "- ✅ Disk usage is safe (Root ${ROOTUSE:-?}% full)."
  fi

  # Logs check
  if command -v journalctl >/dev/null 2>&1 && journalctl -p 3 -n 20 --no-pager | grep -q "I/O error"; then
    echo "- ⚠️ Kernel is logging I/O errors (often phantom floppy/CD in VMs)."
  else
    echo "- ✅ No critical kernel I/O errors detected."
  fi

  # Failed services
  FAILED_CNT=$(systemctl --failed --no-legend --type=service 2>/dev/null | wc -l || echo 0)
  if [ "$FAILED_CNT" -gt 0 ]; then
    echo "- ⚠️ $FAILED_CNT services are failed. Run 'systemctl --failed' to review."
  else
    echo "- ✅ All systemd services are running normally."
  fi

  # Time sync
  if command -v timedatectl >/dev/null 2>&1 && timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then
    echo "- ✅ System clock is synchronized via NTP."
  else
    echo "- ⚠️ System clock is NOT synchronized. Check NTP."
  fi

  echo
  echo "[Verdict] Overall system health looks stable unless flagged above."
  echo "============================================================"
}

log "=== Linux Auto-Debug + Self-Heal ==="
log "Host: $(hostname -f 2>/dev/null || hostname)  |  Time (UTC): $START_TS"
hr

# -------- Detect OS family --------
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  ID_LC="${ID,,}"
  LIKE="${ID_LIKE:-}"
else
  ID_LC="$(uname -s)"
  LIKE=""
fi

IS_DEBIAN=false
IS_RHEL=false
case "$ID_LC:$LIKE" in
  *ubuntu*:*|*debian*:*|debian:*|ubuntu:*) IS_DEBIAN=true ;;
  *almalinux*:*|*rocky*:*|*rhel*:*|*centos*:*|*fedora*:*|:*rhel*|:*fedora*) IS_RHEL=true ;;
esac

log "Detected OS: ${PRETTY_NAME:-$ID_LC}  |  Kernel: $(uname -r)"
hr

# -------- Helpers per family --------
PKG_UPDATE="true"
PKG_CLEAN="true"
SYSLOG_FILE=""
SECURE_FILE=""
if $IS_DEBIAN; then
  PKG_UPDATE="apt-get update -y && apt-get upgrade -y"
  PKG_CLEAN="apt-get clean"
  SYSLOG_FILE="/var/log/syslog"
  SECURE_FILE="/var/log/auth.log"
elif $IS_RHEL; then
  PKG_UPDATE="dnf -y update"
  PKG_CLEAN="dnf -y clean all"
  SYSLOG_FILE="/var/log/messages"
  SECURE_FILE="/var/log/secure"
else
  SYSLOG_FILE="/var/log/messages"
fi

# -------- Baseline Health --------
log "[System] Uptime / Load"
uptime || true
echo
echo "[Explanation] Shows how long the system has been running, logged-in users, and load average. Near 0 = idle."
hr

log "[System] CPU/Memory top offenders"
ps aux --sort=-%cpu | head -n 8
echo
ps aux --sort=-%mem | head -n 8
echo
echo "[Explanation] Processes using most CPU and RAM. Use to spot runaway tasks."
hr

log "[Memory] free -h"
free -h || true
echo
echo "[Explanation] Total/used/available memory. Very low 'available' can cause swapping or slowdowns."
hr

log "[Disk] Filesystems (df -hT)"
df -hT | grep -v tmpfs || true
echo

DISK_ALERTS=0
while read -r fs type size used avail usep mount; do
  [[ "$usep" = *"Use%"* ]] && continue
  pct=${usep%%%}
  if [[ "$pct" -ge 85 ]]; then
    log "ALERT: $mount at ${pct}% used ($fs)"
    ((DISK_ALERTS++))
  fi
done < <(df -hPT | awk 'NR>1 {print $1,$2,$3,$4,$5,$6,$7}')
echo
echo "[Explanation] Disk usage by filesystem. Alerts if any mount exceeds 85%."
hr

log "[Network] Interfaces"
ip -brief a || true
echo
log "[Network] Routes"
ip route || true
echo
log "[Network] Open ports (top 15)"
ss -tulnp 2>/dev/null | head -n 15 || true
echo
echo "[Explanation] Interfaces, routing, and listening ports. Keep the open-port list minimal for security."
hr

# -------- Services --------
log "[Services] Running services (head)"
systemctl list-units --type=service --state=running --no-pager | head -n 20 || true
echo
log "[Services] Failed services"
FAILED_UNITS=$(systemctl --failed --no-legend --plain --type=service 2>/dev/null | awk '{print $1}')
if [[ -n "$FAILED_UNITS" ]]; then
  echo "$FAILED_UNITS"
else
  echo "None"
fi
echo
echo "[Explanation] Active services and any failures. Failed units often explain app outages."
hr

# -------- Logs --------
log "[Logs] Recent errors (journalctl -p 3)"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -p 3 -n 40 --no-pager || true
fi
echo
if [[ -f "$SYSLOG_FILE" ]]; then
  log "[Logs] Tail $SYSLOG_FILE (errors/warnings)"
  tail -n 200 "$SYSLOG_FILE" | grep -Ei "error|warn|fail" | tail -n 40 || true
fi
echo
echo "[Explanation] Recent system errors/warnings. Common harmless VM messages: floppy/CD I/O, SMBus notices."
hr

# -------- DNS quick sanity --------
RESOLV="/etc/resolv.conf"
DNS_ALERT=false
log "[DNS] resolv.conf"
head -n 10 "$RESOLV" || true
VALID_DNS=false
if grep -Eq '^\s*nameserver\s+[0-9a-fA-F:.]+' "$RESOLV"; then
  VALID_DNS=true
else
  DNS_ALERT=true
  log "ALERT: No valid nameserver lines found in $RESOLV"
fi
echo
echo "[Explanation] DNS configuration. Missing nameserver lines can break name resolution."
hr

# -------- Time sync --------
TIME_ALERT=false
if command -v timedatectl >/dev/null 2>&1; then
  log "[Time] timedatectl status"
  timedatectl status || true
  if ! timedatectl show | grep -q 'NTPSynchronized=yes'; then
    TIME_ALERT=true
    log "ALERT: NTP not synchronized"
  fi
  echo
  echo "[Explanation] Time source and NTP sync. Accurate time is critical for auth/logs."
  hr
fi

# -------- SELinux (RHEL) --------
if command -v getenforce >/dev/null 2>&1; then
  SEL=$(getenforce || true)
  log "[SELinux] Status: $SEL"
  if [[ "$SEL" == "Enforcing" ]]; then
    log "Tip: If a service starts then fails, check /var/log/audit/audit.log for denials."
  fi
  echo
  echo "[Explanation] SELinux mode (Enforcing/Permissive/Disabled). Denials can block services."
  hr
fi

# -------- Disk triage (biggest dirs) --------
log "[Disk] Biggest paths under /var (top 10)"
du -xhd1 /var 2>/dev/null | sort -h | tail -n 10 || true
echo
log "[Disk] Biggest logs in /var/log (top 10)"
du -sh /var/log/* 2>/dev/null | sort -h | tail -n 10 || true
echo
echo "[Explanation] Space hotspots under /var and /var/log. Useful when disks fill up."
hr

# -------- Deleted-but-open files (leaking space) --------
log "[Disk] Files deleted but still held open by processes"
if command -v lsof >/dev/null 2>&1; then
  LDEL=$(lsof +L1 2>/dev/null | awk 'NR<=20{print}' || true)
  if [[ -n "$LDEL" ]]; then
    echo "$LDEL"
    echo
    log "NOTE: Restarting the owning service releases the space."
  else
    echo "None"
  fi
else
  echo "lsof not installed"
fi
echo
echo "[Explanation] Deleted files still open keep consuming space until the process restarts."
hr

# =====================================================================
#                          REMEDIATIONS
# =====================================================================
need_root

if ! $APPLY; then
  final_summary
  log "Read-only run complete. Re-run with --apply for safe fixes."
  exit 0
fi

log "=== APPLY MODE: Performing safe remediations ==="

# 1) Restart failed services (collect logs before/after)
if [[ -n "${FAILED_UNITS:-}" ]]; then
  log "[Fix] Restarting FAILED services"
  while read -r unit; do
    [[ -z "$unit" ]] && continue
    log " -> $unit (logs last 30 lines)"
    systemctl status "$unit" --no-pager -l | tail -n 30 || true
    run_safe "systemctl restart '$unit'"
    sleep 1
    systemctl --no-pager -l status "$unit" | head -n 10 || true
  done <<< "$FAILED_UNITS"
else
  log "[Fix] No failed services to restart"
fi
hr

# 2) Disk space relief (journals, logrotate, truncate largest logs, pkg cache, tmp)
if (( DISK_ALERTS > 0 )); then
  log "[Fix] Disk high usage detected on one or more mounts"
fi

# Vacuum journals to 200MB or 7 days (whichever hits first)
if command -v journalctl >/dev/null 2>&1; then
  log "[Fix] Vacuuming systemd journals (200M OR 7d)"
  run_safe "journalctl --vacuum-size=200M"
  run_safe "journalctl --vacuum-time=7d"
fi

# Force logrotate if present
if [[ -x /usr/sbin/logrotate || -x /sbin/logrotate ]]; then
  log "[Fix] Forcing logrotate"
  run_safe "logrotate -f /etc/logrotate.conf"
fi

# Truncate single huge logs (>300MB) cautiously
log "[Fix] Truncating very large logs (>300MB) under /var/log"
while read -r size path; do
  num=${size%[KMG]}
  unit=${size##*$num}
  over=false
  case "$unit" in
    G|T) over=true ;;
    M) [[ ${num%.*} -ge 300 ]] && over=true ;;
  esac
  if $over; then
    log "  - truncating $path ($size)"
    run_safe "truncate -s 0 '$path'"
  fi
done < <(du -h /var/log/* 2>/dev/null | sort -h | tail -n 50)

# Clean package caches
log "[Fix] Cleaning package caches"
run_safe "$PKG_CLEAN"

# Clear stale tmp (files older than 7 days)
log "[Fix] Clearing old files in /tmp (>=7d)"
run_safe "find /tmp -mindepth 1 -mtime +7 -print -delete"

# 3) Release deleted-but-open files (aggressive)
if $AGGRESSIVE && command -v lsof >/dev/null 2>&1; then
  log "[Fix][Aggressive] Restarting services holding deleted files"
  while read -r pid comm; do
    [[ -z "$pid" ]] && continue
    svc=$(systemctl status "$pid" 2>/dev/null | awk -F';' '/Loaded:/{print $1}' | awk '{print $2}' || true)
    if [[ -n "$svc" ]]; then
      log "  -> restarting $svc (pid $pid: $comm)"
      run_safe "systemctl restart '$svc'"
    else
      log "  -> process $comm (pid $pid) holds deleted files; consider restart"
    fi
  done < <(lsof +L1 2>/dev/null | awk 'NR>1 {print $2,$1}' | sort -u | head -n 10)
else
  log "[Fix] Skipping aggressive restarts (use --aggressive)"
fi
hr

# 4) DNS fallback if no valid resolvers
if $DNS_ALERT; then
  log "[Fix] Adding safe DNS fallback"
  if systemctl is-active --quiet systemd-resolved; then
    run_safe "resolvectl dns $(hostname -I | awk '{print $1}') 1.1.1.1 8.8.8.8"
    log "Set DNS via systemd-resolved (added 1.1.1.1, 8.8.8.8 as fallback)"
  else
    cp -a "$RESOLV" "${RESOLV}.bak.$(date +%s)" || true
    {
      echo "nameserver 1.1.1.1"
      echo "nameserver 8.8.8.8"
    } >> "$RESOLV"
    log "Appended fallback nameservers to $RESOLV"
  fi
fi
hr

# 5) Time sync nudge
if $TIME_ALERT; then
  log "[Fix] Enabling / nudging time sync"
  if systemctl list-unit-files | grep -q systemd-timesyncd; then
    run_safe "systemctl enable --now systemd-timesyncd"
    run_safe "timedatectl set-ntp true"
  elif systemctl list-unit-files | grep -q chronyd; then
    run_safe "systemctl enable --now chronyd"
  fi
fi
hr

# 6) Post-fix quick verification
log "[Verify] Re-check failed services"
systemctl --failed --no-legend --type=service || true
echo
log "[Verify] Disk usage after fixes"
df -hT | grep -v tmpfs || true
echo
log "[Verify] DNS test"
run_safe "getent hosts example.com || ping -c1 1.1.1.1"
echo
if command -v timedatectl >/dev/null 2>&1; then
  log "[Verify] Time sync"
  timedatectl show | grep -E 'NTPSynchronized|TimeUSec' || true
fi
hr

log "=== Done. Apply mode completed at $(date -u +'%Y-%m-%dT%H:%M:%SZ') ==="
final_summary
