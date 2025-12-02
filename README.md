# mergerfs + SnapRAID Setup for Immich Server

Automated setup and management scripts for a mergerfs + SnapRAID storage solution optimized for Immich photo server with 15-20TB+ capacity.

## Overview

This setup provides:
- **mergerfs**: Combines multiple drives into a single storage pool
- **SnapRAID**: Provides parity-based protection against drive failures
- **Automation**: Daily syncs and weekly scrubs via systemd timers
- **Safety**: Pre-sync validation, deletion thresholds, and email notifications
- **Monitoring**: Comprehensive logging and SMART disk health checks

## Quick Start

### Prerequisites

- Ubuntu/Debian-based system
- Multiple data drives (2+ recommended)
- 1-2 parity drives
- Root access

### Drive Size Requirements

**Important:** Unlike traditional RAID, mergerfs + SnapRAID does NOT require same-size drives!

- **Data drives:** Can be ANY size, mixed sizes work perfectly
  - Example: 4TB + 6TB + 8TB all in the same pool
  - You'll get full capacity of all drives combined

- **Parity drives:** Must be equal to or LARGER than your largest data drive
  - If largest data drive is 10TB, parity must be ≥10TB
  - Can be larger than the largest data drive (extra space unused for parity)

**Example setup:**
```
Data drives:   4TB + 6TB + 8TB = 18TB usable storage
Parity drive:  8TB (matches largest data drive)
With 1-parity: Protected against 1 disk failure
With 2-parity: Protected against 2 simultaneous disk failures
```

### Preparing Drives

**The setup script does NOT format drives automatically** (for safety).

If you need to format drives before setup:

1. **Use the included format helper script:**
   ```bash
   sudo ./format-disk.sh
   ```
   This will:
   - Show all available disks
   - Safely format selected disk as ext4
   - Multiple safety confirmations

2. **Or format manually:**
   ```bash
   # Replace sdX with your disk (e.g., sda, sdb)
   sudo wipefs -a /dev/sdX
   sudo parted -s /dev/sdX mklabel gpt
   sudo parted -s /dev/sdX mkpart primary ext4 0% 100%
   sudo mkfs.ext4 -F /dev/sdX1
   ```

**IMPORTANT:**
- Formatting will ERASE ALL DATA on the disk
- Make sure you select the correct disk
- The setup script expects drives to already be formatted with ext4

### Installation

1. **Clone or download this repository:**
   ```bash
   git clone <repository-url>
   cd mergerfs-snapraid
   ```

2. **Make scripts executable:**
   ```bash
   chmod +x setup-mergerfs-snapraid.sh
   chmod +x snapraid-sync.sh
   chmod +x snapraid-diff.sh
   ```

3. **Run the setup script:**
   ```bash
   sudo ./setup-mergerfs-snapraid.sh
   ```

   Or run in dry-run mode first to preview changes:
   ```bash
   sudo ./setup-mergerfs-snapraid.sh --dry-run
   ```

4. **Follow the interactive prompts:**
   - Select data drives
   - Select parity drive(s)
   - Configure mount points
   - Review and confirm configuration
   - Enable automation (optional)

## What Gets Installed

### Scripts

- **`/usr/local/bin/snapraid-sync.sh`** - Automated sync with safety checks
- **`/usr/local/bin/snapraid-diff.sh`** - Pre-sync change report

### Systemd Services

- **`snapraid-sync.service`** - Sync service
- **`snapraid-sync.timer`** - Daily sync at 2 AM
- **`snapraid-scrub.service`** - Scrub service
- **`snapraid-scrub.timer`** - Weekly scrub on Sunday at 3 AM

### Configuration

- **`/etc/snapraid.conf`** - SnapRAID configuration
- **`/etc/fstab`** - Updated with drive mounts and mergerfs pool

### Logs

- **`/var/log/snapraid/`** - All sync and scrub logs

## File Descriptions

### 1. setup-mergerfs-snapraid.sh

Main setup script that:
- Detects available disks
- Guides through interactive configuration
- Installs required packages (mergerfs, snapraid)
- Configures /etc/fstab
- Creates SnapRAID configuration
- Sets up automation
- Configures permissions for Immich

**Usage:**
```bash
sudo ./setup-mergerfs-snapraid.sh [--dry-run]
```

### 2. format-disk.sh

Disk formatting helper script that:
- Lists all available disks with details
- Safely formats selected disk as ext4
- Creates GPT partition table
- Multiple safety confirmations before wiping data
- Shows UUID after formatting

**Usage:**
```bash
sudo ./format-disk.sh
```

**Features:**
- Interactive disk selection
- Checks if disk is mounted (prevents accidents)
- Triple confirmation before erasing data
- Works with SATA, SAS, and NVMe drives
- Shows next steps after formatting

**CAUTION:** This will PERMANENTLY ERASE ALL DATA on the selected disk!

### 3. snapraid-sync.sh

Automated sync script with safety features:
- Pre-sync SMART health check
- Diff analysis with change detection
- Deletion threshold protection (aborts if >500 files deleted)
- Unmounted disk detection
- Email notifications (configurable)
- Detailed logging with rotation

**Usage:**
```bash
sudo /usr/local/bin/snapraid-sync.sh
```

**Configuration:**
Edit the script to customize:
- `DELETE_THRESHOLD` - Max deleted files before abort (default: 500)
- `UPDATE_THRESHOLD` - Warning threshold for updates (default: 10000)
- `EMAIL_ENABLED` - Enable email notifications (default: false)
- `EMAIL_TO` - Notification recipient
- `EMAIL_FROM` - Notification sender

### 4. snapraid-diff.sh

Generate a detailed report of changes since last sync:
- Shows added, removed, updated, moved, and copied files
- Color-coded output for easy reading
- Warnings for large deletions or unmounted disks
- Useful for reviewing changes before manual sync

**Usage:**
```bash
sudo /usr/local/bin/snapraid-diff.sh
```

### 5. Systemd Services & Timers

**snapraid-sync.service**
- Runs the sync script
- Low priority (idle CPU and I/O scheduling)
- 10-hour timeout for large syncs

**snapraid-sync.timer**
- Triggers daily at 2 AM
- Persistent (runs on boot if missed)
- 30-minute random delay

**snapraid-scrub.service**
- Scrubs 8% of array (full scrub every ~12 weeks)
- Only scrubs data older than 10 days
- 24-hour timeout

**snapraid-scrub.timer**
- Triggers weekly on Sunday at 3 AM
- Persistent (runs on boot if missed)
- 1-hour random delay

## Manual Commands

### Status & Information

```bash
# Check array status
sudo snapraid status

# View recent changes (diff)
sudo snapraid diff
sudo /usr/local/bin/snapraid-diff.sh  # colored output

# List all files in array
sudo snapraid list

# Check SMART health
sudo snapraid smart
```

### Sync Operations

```bash
# Manual sync
sudo snapraid sync

# Sync with safety checks (recommended)
sudo /usr/local/bin/snapraid-sync.sh

# Force sync (bypass safety checks)
sudo snapraid sync -f
```

### Scrub Operations

```bash
# Scrub 8% of array
sudo snapraid scrub -p 8 -o 10

# Scrub specific percentage
sudo snapraid scrub -p 15

# Scrub specific disk
sudo snapraid scrub -d d1
```

### Maintenance

```bash
# Check timer status
sudo systemctl status snapraid-sync.timer
sudo systemctl status snapraid-scrub.timer

# View recent logs
sudo journalctl -u snapraid-sync.service -n 100
sudo journalctl -u snapraid-scrub.service -n 100

# Enable/disable timers
sudo systemctl enable snapraid-sync.timer
sudo systemctl disable snapraid-sync.timer

# Run service manually
sudo systemctl start snapraid-sync.service
```

## Recovery Procedures

### Single Disk Failure

1. **Identify the failed disk:**
   ```bash
   sudo snapraid status
   sudo snapraid smart
   ```

2. **Replace the failed disk with a new one**

3. **Mount the new disk at the original location**
   ```bash
   # Format the disk (replace /dev/sdX)
   sudo mkfs.ext4 /dev/sdX

   # Mount at original location (e.g., /mnt/disk1)
   sudo mount /dev/sdX /mnt/disk1

   # Update /etc/fstab with new UUID
   sudo blkid /dev/sdX
   ```

4. **Restore data from parity:**
   ```bash
   # Fix all files on the disk
   sudo snapraid fix -d d1

   # Or fix specific files
   sudo snapraid fix -f /path/to/file
   ```

### Multiple File Corruption

1. **Check for corrupted files:**
   ```bash
   sudo snapraid scrub
   ```

2. **Fix corrupted files:**
   ```bash
   sudo snapraid fix
   ```

### Accidental Deletion Recovery

**IMPORTANT:** SnapRAID is NOT real-time backup. Files are only protected after a sync.

1. **DO NOT sync immediately after accidental deletion**

2. **Check what would be lost:**
   ```bash
   sudo snapraid diff
   ```

3. **If files were synced before deletion:**
   - Files cannot be recovered (SnapRAID will see this as legitimate deletion)
   - Restore from separate backup if available

4. **If files were never synced:**
   - Files never had parity protection
   - Cannot be recovered via SnapRAID

### Unmounted Disk Issue

If diff/sync detects unmounted disk:

1. **Check disk status:**
   ```bash
   df -h
   lsblk
   sudo dmesg | tail -50
   ```

2. **Remount the disk:**
   ```bash
   sudo mount -a
   ```

3. **If disk won't mount:**
   - Check disk health: `sudo smartctl -a /dev/sdX`
   - Check filesystem: `sudo fsck /dev/sdX`
   - Review system logs: `sudo journalctl -xe`

## mergerfs Configuration

The setup uses the following mergerfs options:

- **`category.create=mfs`** - Create new files on drive with most free space
- **`moveonenospc=true`** - Automatically move files if drive fills up
- **`minfreespace=50G`** - Reserve 50GB free space on each drive
- **`use_ino`** - Consistent inode numbers
- **`cache.files=partial`** - Partial file caching for performance
- **`dropcacheonclose=true`** - Drop cache when files close

### Checking mergerfs Pool

```bash
# View pool status
df -h /mnt/storage

# View individual disk usage
df -h | grep /mnt/disk

# Check which disk a file is on
ls -l /mnt/disk*/<path-to-file>
```

## SnapRAID Configuration

Key settings in `/etc/snapraid.conf`:

- **Block size:** 256 KiB (optimal for large photo files)
- **Hash size:** 16 bytes (good balance of speed/collision resistance)
- **Auto-save:** Every 10 GB during sync
- **Content files:** Stored on multiple disks for redundancy

## Immich Integration

### Configure Immich to Use Storage Pool

1. **Set library location in docker-compose.yml:**
   ```yaml
   services:
     immich-server:
       volumes:
         - /mnt/storage/immich-library:/usr/src/app/upload
   ```

2. **Create directory with proper permissions:**
   ```bash
   sudo mkdir -p /mnt/storage/immich-library
   sudo chown -R <immich-uid>:<immich-gid> /mnt/storage/immich-library
   ```

3. **Restart Immich:**
   ```bash
   docker-compose down
   docker-compose up -d
   ```

### Recommended Sync Schedule

- **Sync:** Daily (photos uploaded daily)
- **Scrub:** Weekly (verify data integrity)
- **SMART check:** Built into sync script

## Best Practices

### Regular Maintenance

1. **Monitor logs monthly:**
   ```bash
   ls -lh /var/log/snapraid/
   tail -100 /var/log/snapraid/sync-*.log
   ```

2. **Review timer status:**
   ```bash
   sudo systemctl list-timers | grep snapraid
   ```

3. **Check disk health quarterly:**
   ```bash
   sudo snapraid smart
   ```

4. **Test recovery procedures annually**

### Safety Guidelines

1. **Always review diff before manual sync:**
   ```bash
   sudo /usr/local/bin/snapraid-diff.sh
   ```

2. **Never ignore deletion warnings** - Investigate before syncing

3. **Keep multiple content file copies** - Setup creates 3 by default

4. **Verify mounts before adding data:**
   ```bash
   df -h
   mount | grep /mnt
   ```

5. **Maintain offsite backups for critical data** - SnapRAID is not a backup solution

### Performance Tips

1. **Sync regularly** - Smaller, frequent syncs are faster than large infrequent ones

2. **Use SSD for OS and SnapRAID content files** - Improves sync performance

3. **Schedule syncs during low activity** - Default 2 AM is usually good

4. **Monitor disk I/O during operations:**
   ```bash
   iostat -x 5
   ```

## Troubleshooting

### Sync Fails with Lock File Error

```bash
# Remove stale lock file
sudo rm -f /var/run/snapraid-sync.lock
```

### Large Number of Deletions Detected

1. **Verify all disks are mounted:**
   ```bash
   df -h | grep /mnt/disk
   ```

2. **Check for filesystem issues:**
   ```bash
   sudo dmesg | grep -i error
   ```

3. **Review recent system changes**

4. **If deletions are legitimate:**
   ```bash
   # Manually sync with higher threshold
   sudo snapraid sync
   ```

### Email Notifications Not Working

1. **Install mail utilities:**
   ```bash
   sudo apt-get install mailutils
   ```

2. **Configure mail server** (postfix, sendmail, or external SMTP)

3. **Test email:**
   ```bash
   echo "Test" | mail -s "Test" your@email.com
   ```

4. **Enable in sync script:**
   Edit `/usr/local/bin/snapraid-sync.sh`:
   ```bash
   EMAIL_ENABLED=true
   EMAIL_TO="your@email.com"
   ```

### Scrub Reports Errors

```bash
# Run fix to repair errors
sudo snapraid fix

# If many errors, check disk health
sudo snapraid smart

# Run extended SMART test
sudo smartctl -t long /dev/sdX
```

## Expanding Storage

### Adding a New Data Disk

1. **Prepare the disk:**
   ```bash
   sudo mkfs.ext4 /dev/sdX
   sudo mkdir /mnt/diskN
   ```

2. **Add to /etc/fstab:**
   ```bash
   UUID=<disk-uuid> /mnt/diskN ext4 defaults,nofail 0 2
   ```

3. **Mount the disk:**
   ```bash
   sudo mount -a
   ```

4. **Update SnapRAID config** (`/etc/snapraid.conf`):
   ```
   disk dN /mnt/diskN
   content /mnt/diskN/.snapraid.content
   ```

5. **Update mergerfs mount in /etc/fstab:**
   ```
   /mnt/disk1:/mnt/disk2:/mnt/diskN /mnt/storage fuse.mergerfs ...
   ```

6. **Remount mergerfs:**
   ```bash
   sudo umount /mnt/storage
   sudo mount -a
   ```

7. **Sync SnapRAID:**
   ```bash
   sudo snapraid sync
   ```

### Adding a Second Parity Disk

1. **Prepare the parity disk:**
   ```bash
   sudo mkfs.ext4 /dev/sdX
   sudo mkdir /mnt/parity2
   ```

2. **Add to /etc/fstab:**
   ```bash
   UUID=<disk-uuid> /mnt/parity2 ext4 defaults,nofail 0 2
   ```

3. **Update SnapRAID config:**
   ```
   2-parity /mnt/parity2/snapraid.2-parity
   ```

4. **Sync (will take a long time for initial 2-parity calculation):**
   ```bash
   sudo snapraid sync
   ```

## Uninstallation

To remove the setup:

1. **Stop and disable timers:**
   ```bash
   sudo systemctl stop snapraid-sync.timer snapraid-scrub.timer
   sudo systemctl disable snapraid-sync.timer snapraid-scrub.timer
   ```

2. **Unmount mergerfs pool:**
   ```bash
   sudo umount /mnt/storage
   ```

3. **Remove entries from /etc/fstab**

4. **Remove systemd files:**
   ```bash
   sudo rm /etc/systemd/system/snapraid-*.{service,timer}
   sudo systemctl daemon-reload
   ```

5. **Remove scripts:**
   ```bash
   sudo rm /usr/local/bin/snapraid-{sync,diff}.sh
   ```

6. **Optionally remove packages:**
   ```bash
   sudo apt-get remove mergerfs snapraid
   ```

## Important Notes

- **SnapRAID is NOT real-time backup** - Files are only protected after sync
- **SnapRAID protects against disk failure, not deletion** - Use separate backups
- **Test recovery procedures** - Ensure you can actually recover data
- **Monitor SMART status** - Replace drives showing signs of failure
- **Keep firmware updated** - Both drives and RAID controller (if applicable)
- **Document your setup** - Record drive serial numbers and positions

## Resources

- [SnapRAID Manual](https://www.snapraid.it/manual)
- [mergerfs Documentation](https://github.com/trapexit/mergerfs)
- [Immich Documentation](https://immich.app/docs)

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review logs in `/var/log/snapraid/`
3. Check SnapRAID status: `sudo snapraid status`
4. Consult official documentation

## License

Scripts provided as-is. Modify as needed for your setup.

---

**Generated by mergerfs-snapraid setup script**
