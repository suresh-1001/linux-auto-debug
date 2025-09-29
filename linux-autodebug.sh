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
  --apply       Perform safe remediations (journals vacuum, logrotate, restart failed services, fix DNS fallback, clear pkg caches, time sync)
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
run_safe() { # run a cmd and ignore failure, print error
  bash -c "$1" || log "WARN: '$1' failed (continuing)"
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
log "[System] CPU/Memory top offenders"
ps aux --sort=-%cpu | head -n 8
echo
ps aux --sort=-%mem | head -n 8
hr

log "[Memory] free -h"
free -h || true
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
hr

log "[Network] Interfaces"
ip -brief a || true
echo
log "[Network] Routes"
ip route || true
echo
log "[Network] Open ports (top 15)"
ss -tulnp 2>/dev/null | head -n 15 || true
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
  hr
fi

# -------- SELinux (RHEL) --------
if command -v getenforce >/dev/null 2>&1; then
  SEL=$(getenforce || true)
  log "[SELinux] Status: $SEL"
  if [[ "$SEL" == "Enforcing" ]]; then
    log "Tip: If a service starts then fails, check /var/log/audit/audit.log for denials."
  fi
  hr
fi

# -------- Disk triage (biggest dirs) --------
log "[Disk] Biggest paths under /var (top 10)"
du -xhd1 /var 2>/dev/null | sort -h | tail -n 10 || true
echo
log "[Disk] Biggest logs in /var/log (top 10)"
du -sh /var/log/* 2>/dev/null | sort -h | tail -n 10 || true
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
hr

# =====================================================================
#                          REMEDIATIONS
# =====================================================================
need_root

if ! $APPLY; then
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
  # human size like 1.1G -> convert rough threshold check by suffix
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
  # Prefer systemd-resolved if active
  if systemctl is-active --quiet systemd-resolved; then
    run_safe "resolvectl dns $(hostname -I | awk '{print $1}') 1.1.1.1 8.8.8.8"
    log "Set DNS via systemd-resolved (added 1.1.1.1, 8.8.8.8 as fallback)"
  else
    # simple append (preserve existing file)
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
