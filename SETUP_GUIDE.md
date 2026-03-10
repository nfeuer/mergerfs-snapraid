# Setup Guide: mergerfs + SnapRAID for Immich

This guide walks you through planning, installing, and validating a mergerfs + SnapRAID storage pool from scratch. Follow the sections in order for a fresh install.

---

## Table of Contents

1. [Understanding the Architecture](#1-understanding-the-architecture)
2. [Hardware Planning](#2-hardware-planning)
3. [System Prerequisites](#3-system-prerequisites)
4. [Preparing Your Drives](#4-preparing-your-drives)
5. [Running the Setup Wizard](#5-running-the-setup-wizard)
6. [Verifying the Installation](#6-verifying-the-installation)
7. [Configuring Immich](#7-configuring-immich)
8. [Automation and Scheduling](#8-automation-and-scheduling)
9. [Email Notifications](#9-email-notifications)
10. [Ongoing Maintenance](#10-ongoing-maintenance)
11. [Recovery Procedures](#11-recovery-procedures)
12. [Expanding Storage](#12-expanding-storage)
13. [Troubleshooting](#13-troubleshooting)
14. [Uninstallation](#14-uninstallation)

---

## 1. Understanding the Architecture

### How the Stack Works

```
Physical Drives
├── /dev/sda  (data disk 1)  ──>  /mnt/disk1  ─┐
├── /dev/sdb  (data disk 2)  ──>  /mnt/disk2  ─┼──> mergerfs ──> /mnt/storage
├── /dev/sdc  (data disk 3)  ──>  /mnt/disk3  ─┘         (unified pool)
└── /dev/sdd  (parity disk)  ──>  /mnt/parity1
                                       │
                                  SnapRAID parity
                                  (snapraid.parity)
```

**mergerfs** presents the individual data drives as a single mount at `/mnt/storage`. Immich (and any other application) only ever sees `/mnt/storage`.

**SnapRAID** reads the data drives directly (not through mergerfs) and maintains a parity file on the parity drive. If a data drive fails, parity can reconstruct its contents.

### Key Differences from Hardware RAID

| | Hardware RAID | mergerfs + SnapRAID |
|---|---|---|
| Drive size requirement | Must match | Any mix |
| Real-time redundancy | Yes | No (periodic sync) |
| Overhead while idle | Constant | None |
| Add drives without rebuild | No | Yes |
| Recover specific files | Difficult | Easy |
| Works with existing data | No | Yes |

### What SnapRAID Does NOT Do

- **Not real-time:** Files are only protected after you run `snapraid sync`.
- **Not a backup:** It protects against hardware failure, not accidental deletion.
- **Not RAID 5/6:** Drives are not striped. If a data drive fails *before* a sync, unsynced files on that drive are lost.

---

## 2. Hardware Planning

### Minimum Requirements

- **2+ data drives** (the drives that store your photos/files)
- **1 parity drive** (must be ≥ the size of your largest data drive)
- Ubuntu 22.04+ or Debian 11+ (or compatible derivative)
- Root / sudo access

### Parity Drive Sizing Rules

| Your data drives | Minimum parity drive size |
|-----------------|--------------------------|
| 4 TB, 4 TB | 4 TB |
| 4 TB, 6 TB, 8 TB | 8 TB |
| 4 TB, 6 TB, 8 TB, 10 TB | 10 TB |

> The parity drive can be *larger* than the biggest data drive — the extra space simply goes unused for parity.

### Choosing 1 vs 2 Parity Drives

| | 1 Parity | 2 Parity |
|---|---|---|
| Tolerates simultaneous failures | 1 drive | 2 drives |
| Parity space used | = largest data drive | = 2× largest data drive |
| Sync time | Faster | Slower |

For most home setups, 1 parity is sufficient. Add a second parity only if you have 5+ data drives or particularly valuable data.

### Example Configurations

**Small setup (18 TB usable):**
```
Data:    /dev/sda  4 TB  →  /mnt/disk1
         /dev/sdb  6 TB  →  /mnt/disk2
         /dev/sdc  8 TB  →  /mnt/disk3
Parity:  /dev/sdd  8 TB  →  /mnt/parity1
Pool:    /mnt/storage  (18 TB visible to Immich)
```

**Larger setup (44 TB usable, dual parity):**
```
Data:    /dev/sda   6 TB  →  /mnt/disk1
         /dev/sdb   8 TB  →  /mnt/disk2
         /dev/sdc  10 TB  →  /mnt/disk3
         /dev/sdd  10 TB  →  /mnt/disk4
         /dev/sde  10 TB  →  /mnt/disk5
Parity:  /dev/sdf  10 TB  →  /mnt/parity1
         /dev/sdg  10 TB  →  /mnt/parity2
Pool:    /mnt/storage  (44 TB visible to Immich)
```

---

## 3. System Prerequisites

### Required Packages

The setup script installs these automatically, but you can pre-install them:

```bash
sudo apt-get update
sudo apt-get install -y mergerfs snapraid smartmontools
```

### Verify Package Availability

```bash
# Check mergerfs is available
apt-cache show mergerfs

# Check snapraid is available
apt-cache show snapraid
```

> **Note:** If `snapraid` is not in your default repos (older Ubuntu/Debian), add the SnapRAID PPA or download from [snapraid.it](https://www.snapraid.it/download).

```bash
# For Ubuntu, if snapraid is not found:
sudo add-apt-repository ppa:tikhonov/snapraid
sudo apt-get update
sudo apt-get install -y snapraid
```

### Identify Your Drives

Before running any script, confirm which drives you are working with:

```bash
# List all block devices with sizes and types
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

# Show drive details including current filesystem
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID

# Detailed disk info (run per disk)
sudo fdisk -l /dev/sda
sudo smartctl -i /dev/sda
```

> **Safety tip:** Write down the serial number of each drive and its intended role (data disk 1, parity, etc.) before you begin.

---

## 4. Preparing Your Drives

The setup script **does not format drives** — this is intentional. You must format each drive yourself before running setup.

### Option A: Use the Included Format Helper

```bash
sudo ./format-disk.sh
```

The script will:
1. List all available drives with size, model, and serial
2. Ask you to enter the drive name (e.g., `sdb`)
3. Show the drive's current contents
4. Require you to type `YES` to confirm before erasing anything
5. Create a GPT partition table, a single partition, and format as ext4
6. Print the new UUID

Repeat for each drive (data drives and parity drives).

### Option B: Format Manually

```bash
# Replace sdX with your drive name (e.g., sdb, sdc)
DISK=/dev/sdX

# Wipe existing partition table
sudo wipefs -a $DISK

# Create GPT partition table and single partition
sudo parted -s $DISK mklabel gpt
sudo parted -s $DISK mkpart primary ext4 0% 100%

# Format as ext4 (sdb → sdb1, nvme0n1 → nvme0n1p1)
sudo mkfs.ext4 -F -L "disk-label" ${DISK}1

# Confirm UUID
sudo blkid ${DISK}1
```

### Verify Drives Are Ready

```bash
# All drives should show ext4 filesystem
lsblk -o NAME,SIZE,FSTYPE,UUID

# Test mount each drive temporarily
sudo mkdir -p /mnt/test-mount
sudo mount /dev/sdb1 /mnt/test-mount
df -h /mnt/test-mount
sudo umount /mnt/test-mount
```

---

## 5. Running the Setup Wizard

### Clone the Repository

```bash
git clone <repository-url>
cd mergerfs-snapraid
chmod +x setup-mergerfs-snapraid.sh snapraid-sync.sh snapraid-diff.sh format-disk.sh
```

### Dry Run First (Recommended)

Preview everything the script will do without making any changes:

```bash
sudo ./setup-mergerfs-snapraid.sh --dry-run
```

Review the output carefully — it shows exactly which `/etc/fstab` entries will be added and what `snapraid.conf` will contain.

### Run the Interactive Setup

```bash
sudo ./setup-mergerfs-snapraid.sh
```

The wizard walks through these steps:

#### Step 1 — Select Data Drives

```
Available Disks:
----------------------------------------
1) /dev/sda - 8.0T - (not mounted)
2) /dev/sdb - 6.0T - (not mounted)
3) /dev/sdc - 4.0T - (not mounted)
4) /dev/sdd - 8.0T - (not mounted)
----------------------------------------

Enter disk numbers for DATA drives (space-separated, e.g., '1 2 3'): 1 2 3
```

Select all disks that will hold your data. Do **not** select the parity drive here.

#### Step 2 — Select Parity Drive(s)

```
Enter disk number for PRIMARY parity drive: 4
Enter disk number for SECOND parity drive (or press Enter to skip): [Enter]
```

#### Step 3 — Configure Mount Points

```
Mount point for /dev/sda [default: /mnt/disk1]: [Enter]
Mount point for /dev/sdb [default: /mnt/disk2]: [Enter]
Mount point for /dev/sdc [default: /mnt/disk3]: [Enter]
Mount point for parity 1 disk [default: /mnt/parity1]: [Enter]
mergerfs pool mount point [default: /mnt/storage]: [Enter]
```

Accept defaults unless you have specific requirements.

#### Step 4 — Review and Confirm

The wizard shows a complete summary:

```
========================================
Configuration Summary
========================================

Data Disks:
  /dev/sda -> /mnt/disk1
  /dev/sdb -> /mnt/disk2
  /dev/sdc -> /mnt/disk3

Parity Configuration:
  Parity 1: /dev/sdd -> /mnt/parity1

mergerfs Pool:
  Mount Point: /mnt/storage
  Source Drives: /mnt/disk1 /mnt/disk2 /mnt/disk3
========================================

Do you want to proceed with this configuration? (yes/no): yes
```

#### Step 5 — Package Installation

The script installs `mergerfs`, `snapraid`, and `smartmontools` via apt.

#### Step 6 — Immich Permissions

```
Enter the UID for Immich user [default: 1000]: 1000
Enter the GID for Immich user [default: 1000]: 1000
```

Find Immich's UID/GID with:

```bash
# If Immich is running in Docker
docker exec immich-server id

# Or check docker-compose.yml for PUID/PGID environment variables
```

#### Step 7 — Automation

```
Enable automatic sync timer? (yes/no): yes
Enable automatic scrub timer? (yes/no): yes
```

Enabling both is recommended for production use.

#### Step 8 — Initial Sync

```
Run initial SnapRAID sync now? (yes/no): yes
```

The first sync builds the parity file for all existing data. This can take **several hours** for large arrays — plan accordingly.

### What the Script Creates

| File/Directory | Purpose |
|----------------|---------|
| `/etc/snapraid.conf` | SnapRAID configuration |
| `/etc/fstab` entries | Auto-mount drives and mergerfs pool on boot |
| `/usr/local/bin/snapraid-sync.sh` | Sync automation script |
| `/usr/local/bin/snapraid-diff.sh` | Diff report script |
| `/etc/systemd/system/snapraid-*.{service,timer}` | Automation units |
| `/var/log/snapraid/` | Log directory |
| `/root/mergerfs-snapraid-setup-README.txt` | Summary of your specific config |

---

## 6. Verifying the Installation

Run these checks after setup completes to confirm everything is working.

### Check Mounts

```bash
# Confirm all disks are mounted
df -h | grep /mnt

# Should show individual data disks AND the merged pool
# Example output:
# /dev/sda1    8.0T  100G  7.9T   2% /mnt/disk1
# /dev/sdb1    6.0T   80G  5.9T   2% /mnt/disk2
# /dev/sdc1    4.0T   60G  3.9T   2% /mnt/disk3
# mergerfs      18T  240G   18T   2% /mnt/storage
```

```bash
# Confirm mergerfs is present
mount | grep mergerfs
```

### Check SnapRAID Status

```bash
sudo snapraid status
```

Expected output after a successful initial sync:
```
SnapRAID status report:
   Files: 12345
   Fragmented: 0
   Excess: 0
   Missing: 0
   Rehash: 0
   Unsynced: 0

No error detected.
```

### Check Timers

```bash
sudo systemctl list-timers | grep snapraid
```

Expected output:
```
Sun 2024-01-14 03:00:00 UTC  5 days left  snapraid-scrub.timer
Mon 2024-01-08 02:00:00 UTC  10h left     snapraid-sync.timer
```

### Run a Test Diff

```bash
sudo /usr/local/bin/snapraid-diff.sh
```

Right after a sync this should report "No changes detected."

### Write a Test File

```bash
# Write a test file to the pool
echo "test" | sudo tee /mnt/storage/test.txt

# Confirm it's on one of the data drives
ls /mnt/disk*/test.txt

# Run sync to protect it
sudo snapraid sync

# Confirm sync included the file
sudo snapraid status
```

### Check SMART Health

```bash
sudo snapraid smart
```

All drives should show `OK` status. Investigate any `WARNING` or `FAIL` results immediately.

---

## 7. Configuring Immich

### Set Library Path in docker-compose.yml

```yaml
services:
  immich-server:
    volumes:
      - /mnt/storage/immich-library:/usr/src/app/upload
      # ... other volumes
  immich-microservices:
    volumes:
      - /mnt/storage/immich-library:/usr/src/app/upload
      # ... other volumes
```

### Create the Library Directory

```bash
# Create Immich library directory
sudo mkdir -p /mnt/storage/immich-library

# Set ownership (use Immich's actual UID:GID)
sudo chown -R 1000:1000 /mnt/storage/immich-library
sudo chmod 755 /mnt/storage/immich-library
```

### Apply and Restart

```bash
docker-compose down
docker-compose up -d

# Confirm Immich can write to the pool
docker exec immich-server ls /usr/src/app/upload
```

### Verify Uploads Land on the Pool

After uploading a photo through Immich, confirm it appears on the storage pool:

```bash
# Look for recently created files on the pool
find /mnt/storage/immich-library -newer /tmp -type f | head -5
```

---

## 8. Automation and Scheduling

### Default Schedule

| Timer | Schedule | Action |
|-------|----------|--------|
| `snapraid-sync.timer` | Daily at 2:00 AM ± 30 min | Sync with safety checks |
| `snapraid-scrub.timer` | Sunday at 3:00 AM ± 1 hr | Scrub 8% of array |

The random delay (jitter) prevents contention if multiple systems share the same network storage.

### Customizing the Sync Schedule

Edit `/etc/systemd/system/snapraid-sync.timer`:

```ini
[Timer]
# Run at 3 AM every day
OnCalendar=*-*-* 03:00:00
```

Reload after editing:

```bash
sudo systemctl daemon-reload
sudo systemctl restart snapraid-sync.timer
```

### Changing the Deletion Threshold

Edit `/usr/local/bin/snapraid-sync.sh`:

```bash
# Default: abort if more than 500 files are deleted
DELETE_THRESHOLD=500

# For a media library with many small edits, you might lower this:
DELETE_THRESHOLD=200
```

### Manually Starting Timers/Services

```bash
# Run sync now (outside of timer)
sudo systemctl start snapraid-sync.service

# Run scrub now
sudo systemctl start snapraid-scrub.service

# Watch live output
sudo journalctl -fu snapraid-sync.service
```

### Disabling Automation

```bash
sudo systemctl disable --now snapraid-sync.timer
sudo systemctl disable --now snapraid-scrub.timer
```

---

## 9. Email Notifications

The sync script supports email alerts for failures, threshold violations, and successes.

### Install Mail Utilities

```bash
sudo apt-get install -y mailutils postfix
```

During Postfix setup, choose **"Internet Site"** for direct delivery, or **"Satellite system"** if you relay through an external SMTP server (Gmail, SendGrid, etc.).

### Configure the Sync Script

Edit `/usr/local/bin/snapraid-sync.sh`:

```bash
EMAIL_ENABLED=true
EMAIL_TO="you@example.com"
EMAIL_FROM="snapraid@yourhostname"
EMAIL_SUBJECT_PREFIX="[SnapRAID]"
```

### Test Email Delivery

```bash
echo "Test email from SnapRAID host" | mail -s "SnapRAID Test" you@example.com
```

### Using an External SMTP Relay (Optional)

Install `msmtp` as a drop-in `sendmail` replacement:

```bash
sudo apt-get install -y msmtp msmtp-mta

cat > ~/.msmtprc << EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           smtp.gmail.com
port           587
from           your-address@gmail.com
user           your-address@gmail.com
password       your-app-password
EOF
chmod 600 ~/.msmtprc
```

---

## 10. Ongoing Maintenance

### Daily (Automated)

- SnapRAID sync runs at 2 AM via systemd timer
- SMART health check is included in each sync run

### Weekly (Automated)

- SnapRAID scrub runs on Sunday at 3 AM
- Scrubs 8% of the array per run = full array verified every ~12 weeks

### Monthly (Manual)

```bash
# Review sync logs for warnings or errors
ls -lht /var/log/snapraid/
tail -100 /var/log/snapraid/sync-*.log | grep -E "ERROR|WARNING|SUCCESS"

# Check timer reliability
sudo systemctl list-timers | grep snapraid

# Review SMART trends for all disks
sudo snapraid smart
```

### Quarterly

```bash
# Run a full scrub manually
sudo snapraid scrub -p 100

# Check individual disk health
for disk in /dev/sd?; do
    echo "=== $disk ==="
    sudo smartctl -H $disk
done
```

### Annually

- Physically inspect drive connections and airflow
- Test a recovery procedure in a non-production scenario (see [Recovery Procedures](#11-recovery-procedures))
- Review drive age — consider replacing drives older than 5 years
- Update SnapRAID and mergerfs packages

```bash
sudo apt-get update && sudo apt-get upgrade mergerfs snapraid
```

---

## 11. Recovery Procedures

### Before Any Recovery

Always check current status first:

```bash
sudo snapraid status
sudo snapraid smart
df -h | grep /mnt
```

---

### Scenario 1: Single Data Disk Failure

**Symptoms:** Drive doesn't appear in `lsblk`, filesystem errors in `dmesg`, or SMART failures.

**Steps:**

1. **Identify the failed drive:**
   ```bash
   sudo snapraid status
   sudo dmesg | grep -i error | tail -30
   lsblk
   ```

2. **Do not run sync.** If the drive is missing, `snapraid diff` will show all its files as deleted. Syncing now would erase parity for those files.

3. **Remove the failed drive physically** (if hardware failure) and insert the replacement.

4. **Format the replacement:**
   ```bash
   sudo ./format-disk.sh
   # or manually:
   sudo wipefs -a /dev/sdX
   sudo parted -s /dev/sdX mklabel gpt
   sudo parted -s /dev/sdX mkpart primary ext4 0% 100%
   sudo mkfs.ext4 -F /dev/sdX1
   ```

5. **Update `/etc/fstab`** with the new drive's UUID:
   ```bash
   sudo blkid /dev/sdX1   # note the UUID
   sudo nano /etc/fstab   # replace old UUID with new UUID
   ```

6. **Mount the replacement at the original location:**
   ```bash
   sudo mount -a
   df -h | grep /mnt/disk1  # confirm it's mounted
   ```

7. **Restore data from parity:**
   ```bash
   # Restore all files on disk d1 (use the SnapRAID disk name from snapraid.conf)
   sudo snapraid fix -d d1

   # Or restore a specific file
   sudo snapraid fix -f /mnt/disk1/path/to/file
   ```

8. **Verify restoration:**
   ```bash
   sudo snapraid status
   sudo snapraid scrub -p 100 -d d1
   ```

---

### Scenario 2: Parity Disk Failure

**Symptoms:** Parity drive not accessible or SMART failure.

You do **not** lose any data — the parity disk holds no user data. However, you are now unprotected until parity is rebuilt.

1. Replace the parity disk (format with ext4 as above).
2. Update `/etc/fstab` with the new UUID.
3. Mount it: `sudo mount -a`
4. Rebuild parity:
   ```bash
   sudo snapraid sync
   ```
   This rebuilds the entire parity file, which can take hours.

---

### Scenario 3: Accidental File Deletion

**Critical: Do NOT run `snapraid sync` before recovering!**

SnapRAID's content file (the index of all files) still references the deleted files from the last sync. A new sync would update parity to reflect the deletions, making recovery impossible.

1. **Stop any scheduled syncs immediately:**
   ```bash
   sudo systemctl stop snapraid-sync.timer
   ```

2. **Check what was deleted:**
   ```bash
   sudo snapraid diff
   ```

3. **Restore deleted files:**
   ```bash
   # Restore a specific file
   sudo snapraid fix -f /mnt/disk1/path/to/deleted/file

   # Restore an entire directory
   sudo snapraid fix -f /mnt/disk1/path/to/directory/
   ```

4. **Re-enable the timer after recovery:**
   ```bash
   sudo systemctl start snapraid-sync.timer
   ```

> **Limitation:** Files can only be recovered if they were included in the **last sync**. Files added after the last sync have no parity protection and cannot be recovered by SnapRAID.

---

### Scenario 4: Bit Rot / Silent Data Corruption

SnapRAID detects bit rot during scrub operations.

1. **Run a scrub to identify corruption:**
   ```bash
   sudo snapraid scrub -p 100
   ```

2. **Fix corrupted blocks:**
   ```bash
   sudo snapraid fix
   ```

3. **Verify after fix:**
   ```bash
   sudo snapraid scrub -p 100
   ```

---

### Scenario 5: Unmounted Disk Detected at Sync Time

The sync script aborts automatically if a disk appears to be unmounted (to prevent mass "deletion" of files).

1. **Check what's happening:**
   ```bash
   df -h | grep /mnt
   lsblk
   sudo dmesg | tail -50
   ```

2. **Try remounting:**
   ```bash
   sudo mount -a
   ```

3. **If a disk won't mount, investigate before doing anything else:**
   ```bash
   sudo fsck /dev/sdX1           # check for filesystem errors
   sudo smartctl -a /dev/sdX     # check SMART health
   sudo journalctl -xe           # review system errors
   ```

4. **Only proceed with sync once all disks are confirmed mounted.**

---

## 12. Expanding Storage

### Adding a New Data Drive

1. **Format the new drive:**
   ```bash
   sudo ./format-disk.sh
   ```

2. **Create a mount point:**
   ```bash
   sudo mkdir -p /mnt/disk4
   ```

3. **Add to `/etc/fstab`:**
   ```bash
   # Get UUID
   sudo blkid /dev/sdX1

   # Add to fstab
   echo "UUID=<new-uuid> /mnt/disk4 ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
   ```

4. **Mount it:**
   ```bash
   sudo mount -a
   df -h | grep /mnt/disk4
   ```

5. **Update `/etc/snapraid.conf`** — add the new disk:
   ```
   disk d4 /mnt/disk4
   content /mnt/disk4/.snapraid.content
   ```

6. **Update the mergerfs line in `/etc/fstab`** to include the new disk:
   ```
   /mnt/disk1:/mnt/disk2:/mnt/disk3:/mnt/disk4 /mnt/storage fuse.mergerfs ...
   ```

7. **Remount mergerfs:**
   ```bash
   sudo umount /mnt/storage
   sudo mount -a
   df -h /mnt/storage
   ```

8. **Run sync to include the new disk in parity:**
   ```bash
   sudo snapraid sync
   ```

### Adding a Second Parity Drive

1. **Format the parity disk:**
   ```bash
   sudo ./format-disk.sh
   sudo mkdir -p /mnt/parity2
   ```

2. **Add to `/etc/fstab`:**
   ```bash
   echo "UUID=<parity2-uuid> /mnt/parity2 ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
   sudo mount -a
   ```

3. **Update `/etc/snapraid.conf`** — add the second parity line:
   ```
   2-parity /mnt/parity2/snapraid.2-parity
   ```

4. **Run sync** (this calculates dual parity for the entire array — can take many hours):
   ```bash
   sudo snapraid sync
   ```

### Replacing a Disk with a Larger One

1. Sync the array first to ensure parity is current: `sudo snapraid sync`
2. Copy all data from the old disk to a temporary location or new disk
3. Follow the [Single Data Disk Failure](#scenario-1-single-data-disk-failure) procedure using `snapraid fix` to restore data to the new disk
4. Update `/etc/fstab` with the new UUID and remount

---

## 13. Troubleshooting

### Sync Fails: "Lock file exists"

```bash
# Check if a sync is actually running
ps aux | grep snapraid

# If no sync is running, remove the stale lock
sudo rm -f /var/run/snapraid-sync.lock
```

### Sync Aborts: "Deletion threshold exceeded"

The script detected more deleted files than `DELETE_THRESHOLD` (default: 500). This is a safety feature.

```bash
# Verify all disks are mounted
df -h | grep /mnt/disk

# Check for filesystem errors
sudo dmesg | grep -i "error\|fail"

# Review what SnapRAID sees as deleted
sudo snapraid diff | grep "^-"
```

If the deletions are legitimate (e.g., you intentionally deleted files):
```bash
# Force sync bypassing the script's threshold
sudo snapraid sync
```

### mergerfs Pool Not Showing Correct Size

```bash
# Check individual drives have space
df -h | grep /mnt/disk

# Check mergerfs policy is set correctly
mount | grep mergerfs

# Remount if needed
sudo umount /mnt/storage && sudo mount -a
```

### Files Not Being Written to mergerfs Pool

```bash
# Confirm the pool is mounted
df -h /mnt/storage

# Check permissions on pool
ls -la /mnt/storage

# Test write access
sudo touch /mnt/storage/test-write && sudo rm /mnt/storage/test-write
```

### SnapRAID Reports "Content file not found"

The content file tracks all files in the array. If it's missing, SnapRAID can't operate.

```bash
# Check content file locations (see snapraid.conf)
cat /etc/snapraid.conf | grep "^content"

# List which content files exist
ls -lh /var/snapraid/snapraid.content
ls -lh /mnt/disk*/.*snapraid.content 2>/dev/null
```

If all content files are gone, recovery is not possible without a backup of the content file.

### Scrub Reports Hash Errors After a Fix

```bash
# Run a full disk-level check
sudo smartctl -t long /dev/sdX
sudo smartctl -a /dev/sdX   # check results after ~2 hours

# If SMART shows errors, plan to replace the drive
```

### Package Not Found: snapraid

```bash
# Add SnapRAID PPA (Ubuntu)
sudo add-apt-repository ppa:tikhonov/snapraid
sudo apt-get update
sudo apt-get install -y snapraid

# Or download directly from snapraid.it and install:
wget https://github.com/amadvance/snapraid/releases/download/v12.3/snapraid-12.3.tar.gz
# (check for the latest version at snapraid.it)
```

### Timers Not Running

```bash
# Check timer status
sudo systemctl status snapraid-sync.timer
sudo systemctl status snapraid-scrub.timer

# Check for errors
sudo journalctl -u snapraid-sync.timer -n 50

# Re-enable if disabled
sudo systemctl enable --now snapraid-sync.timer
sudo systemctl enable --now snapraid-scrub.timer

# Verify system time is correct (timers depend on accurate time)
timedatectl status
```

---

## 14. Uninstallation

To fully remove the setup:

### 1. Stop and Disable Timers

```bash
sudo systemctl stop snapraid-sync.timer snapraid-scrub.timer
sudo systemctl disable snapraid-sync.timer snapraid-scrub.timer
```

### 2. Unmount mergerfs Pool

```bash
sudo umount /mnt/storage
```

### 3. Remove fstab Entries

```bash
sudo nano /etc/fstab
# Remove the mergerfs line and all UUID lines added by setup
```

### 4. Remove Systemd Units

```bash
sudo rm /etc/systemd/system/snapraid-sync.service \
        /etc/systemd/system/snapraid-sync.timer \
        /etc/systemd/system/snapraid-scrub.service \
        /etc/systemd/system/snapraid-scrub.timer
sudo systemctl daemon-reload
```

### 5. Remove Scripts and Config

```bash
sudo rm /usr/local/bin/snapraid-sync.sh
sudo rm /usr/local/bin/snapraid-diff.sh
sudo rm /etc/snapraid.conf
```

### 6. Optionally Remove Packages

```bash
sudo apt-get remove mergerfs snapraid
sudo apt-get autoremove
```

### 7. Remove Log Directory

```bash
sudo rm -rf /var/log/snapraid
```

> **Your data on the drives is untouched** — uninstallation only removes the management layer.

---

## Configuration Reference

### `/etc/snapraid.conf` Key Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `block_size` | 256 | Block size in KiB. 256 is optimal for large files (photos, videos). |
| `hashsize` | 16 | Hash bytes. 16 = good balance of speed and collision resistance. |
| `autosave` | 10 | Save progress every N GB during sync. Allows resume after interruption. |
| `content` | (multiple) | Path(s) to the content file. Multiple copies = better redundancy. |

### mergerfs Mount Options

| Option | Value | Description |
|--------|-------|-------------|
| `category.create` | `mfs` | Create new files on the drive with most free space |
| `moveonenospc` | `true` | Move files to another drive if current drive is full |
| `minfreespace` | `50G` | Keep at least 50 GB free on each drive |
| `use_ino` | — | Use consistent inode numbers (required for some applications) |
| `cache.files` | `partial` | Partial file caching for better performance |
| `dropcacheonclose` | `true` | Release page cache when files are closed |

### Sync Script Thresholds (`/usr/local/bin/snapraid-sync.sh`)

| Variable | Default | Description |
|----------|---------|-------------|
| `DELETE_THRESHOLD` | 500 | Abort sync if more than this many files are deleted |
| `UPDATE_THRESHOLD` | 10000 | Warn (but don't abort) if more than this many files updated |
| `EMAIL_ENABLED` | false | Enable email notifications |
| `EMAIL_TO` | — | Recipient address for notifications |

---

*For quick reference commands, see the [README](README.md). For upstream documentation, see [SnapRAID Manual](https://www.snapraid.it/manual) and [mergerfs docs](https://github.com/trapexit/mergerfs).*
