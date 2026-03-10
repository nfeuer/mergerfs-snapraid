# mergerfs + SnapRAID for Immich

Automated setup and management scripts for a **mergerfs + SnapRAID** storage pool — optimized for self-hosted photo servers like [Immich](https://immich.app), with 15–20 TB+ capacity.

> **New to this setup?** Start with the [Setup Guide](SETUP_GUIDE.md) for a complete walkthrough from hardware planning to first sync.

---

## What This Does

| Component | Role |
|-----------|------|
| **mergerfs** | Combines multiple drives into a single unified mount point |
| **SnapRAID** | Parity-based protection against drive failure or bit-rot |
| **Systemd timers** | Daily syncs at 2 AM, weekly scrubs on Sunday at 3 AM |
| **Safety scripts** | Pre-sync diffs, deletion thresholds, SMART checks |

This is **not** real-time RAID. SnapRAID snapshots parity periodically — files are protected only after a sync. This trade-off enables mixed drive sizes, low overhead, and easy recovery without complexity.

---

## Repository Contents

| File | Description |
|------|-------------|
| `setup-mergerfs-snapraid.sh` | Interactive setup wizard — installs packages, configures fstab, SnapRAID, and systemd |
| `format-disk.sh` | Safe helper to format drives as ext4 before setup |
| `snapraid-sync.sh` | Sync automation with SMART checks, diff analysis, and deletion threshold protection |
| `snapraid-diff.sh` | Color-coded pre-sync change report |
| `snapraid-sync.service` / `.timer` | Systemd units for daily sync |
| `snapraid-scrub.service` / `.timer` | Systemd units for weekly scrub |

---

## Quick Start

```bash
# 1. Clone
git clone <repository-url> && cd mergerfs-snapraid

# 2. (Optional) Format any unformatted drives
sudo ./format-disk.sh

# 3. Run the setup wizard
chmod +x setup-mergerfs-snapraid.sh snapraid-sync.sh snapraid-diff.sh
sudo ./setup-mergerfs-snapraid.sh

# 4. Preview without making changes
sudo ./setup-mergerfs-snapraid.sh --dry-run
```

For a full walkthrough including hardware planning, drive sizing, Immich integration, recovery procedures, and troubleshooting, see the **[Setup Guide](SETUP_GUIDE.md)**.

---

## Key Concepts

### Drive Sizing

Unlike traditional RAID, mergerfs + SnapRAID supports **mixed drive sizes**:

- **Data drives:** Any size. Total usable capacity = sum of all drives.
- **Parity drives:** Must be ≥ your largest data drive.

```
Example:  4 TB + 6 TB + 8 TB data  →  18 TB usable
          8 TB parity               →  1-fault tolerance
```

### Sync vs Scrub

| Operation | Command | Frequency | Purpose |
|-----------|---------|-----------|---------|
| Sync | `snapraid sync` | Daily | Update parity to reflect current files |
| Scrub | `snapraid scrub` | Weekly | Verify stored data matches parity |
| Diff | `snapraid diff` | On demand | Preview changes before syncing |

---

## Common Commands

```bash
# Check array status
sudo snapraid status

# Review pending changes before sync
sudo /usr/local/bin/snapraid-diff.sh

# Manual sync (with safety checks)
sudo /usr/local/bin/snapraid-sync.sh

# Scrub 8% of the array
sudo snapraid scrub -p 8 -o 10

# Recover a failed disk (replace d1 with actual disk name)
sudo snapraid fix -d d1

# Check systemd timers
sudo systemctl list-timers | grep snapraid
```

---

## Important Notes

- **SnapRAID is not a real-time backup.** Data is only protected after a sync.
- **SnapRAID protects against disk failure**, not accidental deletion.
- **Do not sync after accidental deletion** until you have reviewed `snapraid diff`.
- Maintain a **separate offsite backup** for truly critical data.

---

## Resources

- [Setup Guide](SETUP_GUIDE.md) — full installation and configuration walkthrough
- [SnapRAID Manual](https://www.snapraid.it/manual)
- [mergerfs Documentation](https://github.com/trapexit/mergerfs)
- [Immich Documentation](https://immich.app/docs)
