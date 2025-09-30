# Linux Auto-Debug & Self-Heal

A portable Bash script that detects the OS (Ubuntu/Debian vs RHEL/Alma/Rocky), runs a baseline health/debug report, and optionally performs safe self-healing actions.

---

## 🚀 Features
- Detects OS family (Debian/Ubuntu vs RHEL/Alma/Rocky).
- Baseline health checks:
  - Uptime, CPU, memory, disk usage
  - Running vs failed services
  - Open ports, routes, DNS sanity
  - Recent system logs and errors
- Disk space triage (biggest directories, deleted-but-open files).
- Optional **safe fixes**:
  - Restart failed services
  - Vacuum journals and rotate logs
  - Clean package caches and old `/tmp` files
  - Add fallback DNS if missing
  - Enable NTP time sync
- **Aggressive mode**: restart processes holding deleted log files.

---

## 📦 Usage

Clone and run:

```bash
git clone https://github.com/suresh-1001/linux-auto-debug.git
cd linux-auto-debug
chmod +x linux-autodebug.sh
```

### Read-only (safe baseline)
```bash
sudo ./linux-autodebug.sh
```

### Apply safe fixes
```bash
sudo ./linux-autodebug.sh --apply
```

### Apply + aggressive (restart processes holding deleted files)
```bash
sudo ./linux-autodebug.sh --apply --aggressive
```

### Save a full report
```bash
sudo ./linux-autodebug.sh --apply --report /root/health-report-$(date +%F).txt
```

---

## 🖥️ Example Output

```
=== Linux Auto-Debug Script ===
Host: demo-vm   |   Time: 2025-09-29T20:30:00Z
--------------------------------
[System] Uptime / Load
  10:20:31 up 3 days,  4:12,  2 users,  load average: 0.15, 0.09, 0.05

[Disk] ALERT: /var at 92% used (/dev/sda1)
[Services] Failed services
  nginx.service
...
```

---

## 🔑 Why This Project Matters
- Showcases **hands-on Linux troubleshooting** skills.
- Demonstrates **automation + prevention mindset**.
- Works across **Ubuntu 24.04** and **AlmaLinux 10** (two common enterprise distros).
- Great for interviews and portfolio.

---

## 📜 License
This project is licensed under the [MIT License](./LICENSE).
