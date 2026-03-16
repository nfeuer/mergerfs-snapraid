#!/bin/bash

#############################################################################
# mergerfs + SnapRAID Setup Script for Immich Server
#
# This script automates the setup of mergerfs and SnapRAID for an Immich
# photo server with multiple data drives and parity protection.
#
# Usage: sudo ./setup-mergerfs-snapraid.sh [--dry-run]
#############################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration defaults
MOUNT_POINT="/mnt/storage"
SNAPRAID_CONF="/etc/snapraid.conf"
SNAPRAID_CONTENT_FILES=3  # Number of content file copies
SYNC_THRESHOLD=1000  # Warning threshold for deleted files
DRY_RUN=false

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            echo -e "${YELLOW}Running in DRY-RUN mode - no changes will be made${NC}"
            ;;
    esac
done

# Logging
LOG_DIR="/var/log/snapraid"
mkdir -p "$LOG_DIR"
SETUP_LOG="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"

log() {
    echo -e "$@" | tee -a "$SETUP_LOG"
}

log_info() {
    log "${BLUE}[INFO]${NC} $@"
}

log_success() {
    log "${GREEN}[SUCCESS]${NC} $@"
}

log_warning() {
    log "${YELLOW}[WARNING]${NC} $@"
}

log_error() {
    log "${RED}[ERROR]${NC} $@"
}

# Resolve a disk device to a partition with a filesystem.
# If /dev/sdb has no UUID but /dev/sdb1 does, return /dev/sdb1.
resolve_partition() {
    local disk=$1
    local uuid
    uuid=$(blkid -s UUID -o value "$disk" 2>/dev/null || true)
    if [[ -n "$uuid" ]]; then
        echo "$disk"
        return
    fi

    # Try first partition (handles both /dev/sdb1 and /dev/nvme0n1p1)
    local part
    if [[ "$disk" =~ nvme ]]; then
        part="${disk}p1"
    else
        part="${disk}1"
    fi

    if [[ -b "$part" ]]; then
        uuid=$(blkid -s UUID -o value "$part" 2>/dev/null || true)
        if [[ -n "$uuid" ]]; then
            log_info "Resolved $disk to partition $part"
            echo "$part"
            return
        fi
    fi

    # Nothing found
    echo "$disk"
}

# Backup existing configuration
backup_config() {
    local file=$1
    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d-%H%M%S)"
        log_info "Backing up $file to $backup"
        if [[ "$DRY_RUN" == false ]]; then
            cp "$file" "$backup"
        fi
    fi
}

# Detect available disks
detect_disks() {
    log_info "Detecting available disks..."

    # Get all block devices excluding loop devices, RAM disks, and mounted on /
    mapfile -t DISKS < <(lsblk -ndo NAME,SIZE,TYPE,MOUNTPOINT | \
        grep -E "disk|part" | \
        grep -v "loop\|ram" | \
        awk '{print $1,$2,$4}')

    if [[ ${#DISKS[@]} -eq 0 ]]; then
        log_error "No disks detected"
        exit 1
    fi

    log_success "Found ${#DISKS[@]} disk(s)/partition(s)"
    echo ""
}

# Display available disks
display_disks() {
    echo -e "${BLUE}Available Disks:${NC}"
    echo "----------------------------------------"
    local i=1
    for disk in "${DISKS[@]}"; do
        local name=$(echo "$disk" | awk '{print $1}')
        local size=$(echo "$disk" | awk '{print $2}')
        local mount=$(echo "$disk" | awk '{print $3}')

        if [[ -z "$mount" ]]; then
            mount="(not mounted)"
        fi

        echo "$i) /dev/$name - $size - $mount"
        ((i++))
    done
    echo "----------------------------------------"
    echo ""
}

# Interactive disk selection
select_data_disks() {
    log_info "Select data disks for mergerfs pool"
    display_disks

    echo -e "${YELLOW}Enter disk numbers for DATA drives (space-separated, e.g., '1 2 3'):${NC}"
    read -r selection

    DATA_DISKS=()
    for num in $selection; do
        if [[ $num -ge 1 ]] && [[ $num -le ${#DISKS[@]} ]]; then
            local disk=$(echo "${DISKS[$((num-1))]}" | awk '{print $1}')
            DATA_DISKS+=("/dev/$disk")
        else
            log_error "Invalid selection: $num"
            exit 1
        fi
    done

    if [[ ${#DATA_DISKS[@]} -lt 2 ]]; then
        log_error "You need at least 2 data disks for mergerfs"
        exit 1
    fi

    log_success "Selected ${#DATA_DISKS[@]} data disk(s): ${DATA_DISKS[*]}"
    echo ""
}

# Select parity disks
select_parity_disks() {
    log_info "Select parity disk(s) for SnapRAID"
    display_disks

    echo -e "${YELLOW}Enter disk number for PRIMARY parity drive:${NC}"
    read -r parity1_num

    if [[ $parity1_num -ge 1 ]] && [[ $parity1_num -le ${#DISKS[@]} ]]; then
        PARITY1_DISK="/dev/$(echo "${DISKS[$((parity1_num-1))]}" | awk '{print $1}')"
    else
        log_error "Invalid selection: $parity1_num"
        exit 1
    fi

    echo -e "${YELLOW}Enter disk number for SECOND parity drive (or press Enter to skip):${NC}"
    read -r parity2_num

    PARITY2_DISK=""
    if [[ -n "$parity2_num" ]]; then
        if [[ $parity2_num -ge 1 ]] && [[ $parity2_num -le ${#DISKS[@]} ]]; then
            PARITY2_DISK="/dev/$(echo "${DISKS[$((parity2_num-1))]}" | awk '{print $1}')"
        else
            log_error "Invalid selection: $parity2_num"
            exit 1
        fi
    fi

    log_success "Parity 1: $PARITY1_DISK"
    if [[ -n "$PARITY2_DISK" ]]; then
        log_success "Parity 2: $PARITY2_DISK"
    fi
    echo ""
}

# Get mount points for data disks
configure_mount_points() {
    log_info "Configuring mount points for data disks"

    MOUNT_POINTS=()
    for i in "${!DATA_DISKS[@]}"; do
        local disk="${DATA_DISKS[$i]}"
        local mount_point="/mnt/disk$((i+1))"

        echo -e "${YELLOW}Mount point for $disk [default: $mount_point]:${NC}"
        read -r custom_mount

        if [[ -n "$custom_mount" ]]; then
            mount_point="$custom_mount"
        fi

        MOUNT_POINTS+=("$mount_point")

        if [[ "$DRY_RUN" == false ]]; then
            mkdir -p "$mount_point"
        fi

        log_info "  $disk -> $mount_point"
    done

    # Get parity mount points
    echo -e "${YELLOW}Mount point for parity 1 disk [default: /mnt/parity1]:${NC}"
    read -r parity1_mount
    PARITY1_MOUNT="${parity1_mount:-/mnt/parity1}"

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$PARITY1_MOUNT"
    fi

    if [[ -n "$PARITY2_DISK" ]]; then
        echo -e "${YELLOW}Mount point for parity 2 disk [default: /mnt/parity2]:${NC}"
        read -r parity2_mount
        PARITY2_MOUNT="${parity2_mount:-/mnt/parity2}"

        if [[ "$DRY_RUN" == false ]]; then
            mkdir -p "$PARITY2_MOUNT"
        fi
    fi

    # Get mergerfs pool mount point
    echo -e "${YELLOW}mergerfs pool mount point [default: $MOUNT_POINT]:${NC}"
    read -r pool_mount
    MOUNT_POINT="${pool_mount:-$MOUNT_POINT}"

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$MOUNT_POINT"
    fi

    echo ""
}

# Display configuration summary
display_summary() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Configuration Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${GREEN}Data Disks:${NC}"
    for i in "${!DATA_DISKS[@]}"; do
        echo "  ${DATA_DISKS[$i]} -> ${MOUNT_POINTS[$i]}"
    done
    echo ""
    echo -e "${GREEN}Parity Configuration:${NC}"
    echo "  Parity 1: $PARITY1_DISK -> $PARITY1_MOUNT"
    if [[ -n "$PARITY2_DISK" ]]; then
        echo "  Parity 2: $PARITY2_DISK -> $PARITY2_MOUNT"
    fi
    echo ""
    echo -e "${GREEN}mergerfs Pool:${NC}"
    echo "  Mount Point: $MOUNT_POINT"
    echo "  Source Drives: ${MOUNT_POINTS[*]}"
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# Confirm configuration
confirm_setup() {
    if [[ "$DRY_RUN" == true ]]; then
        log_warning "DRY-RUN mode: Configuration would be applied"
        return 0
    fi

    echo -e "${YELLOW}Do you want to proceed with this configuration? (yes/no):${NC}"
    read -r confirmation

    if [[ "$confirmation" != "yes" ]]; then
        log_warning "Setup cancelled by user"
        exit 0
    fi
}

# Install required packages
install_packages() {
    log_info "Installing required packages..."

    if [[ "$DRY_RUN" == false ]]; then
        apt-get update
        apt-get install -y mergerfs snapraid smartmontools mailutils
    fi

    log_success "Packages installed"
}

# Setup fstab entries
setup_fstab() {
    log_info "Configuring /etc/fstab"
    backup_config "/etc/fstab"

    local fstab_entries=""

    # Add data disk mounts
    for i in "${!DATA_DISKS[@]}"; do
        local disk
        disk=$(resolve_partition "${DATA_DISKS[$i]}")
        local mount="${MOUNT_POINTS[$i]}"
        local uuid
        uuid=$(blkid -s UUID -o value "$disk" 2>/dev/null || true)

        if [[ -z "$uuid" ]]; then
            log_warning "No UUID found for ${DATA_DISKS[$i]} (or its partitions), skipping fstab entry"
            continue
        fi

        fstab_entries+="UUID=$uuid $mount ext4 defaults,nofail 0 2\n"
    done

    # Add parity disk mounts
    local parity1_resolved
    parity1_resolved=$(resolve_partition "$PARITY1_DISK")
    local parity1_uuid
    parity1_uuid=$(blkid -s UUID -o value "$parity1_resolved" 2>/dev/null || true)
    if [[ -n "$parity1_uuid" ]]; then
        fstab_entries+="UUID=$parity1_uuid $PARITY1_MOUNT ext4 defaults,nofail 0 2\n"
    else
        log_warning "No UUID found for $PARITY1_DISK (or its partitions), skipping fstab entry"
    fi

    if [[ -n "$PARITY2_DISK" ]]; then
        local parity2_resolved
        parity2_resolved=$(resolve_partition "$PARITY2_DISK")
        local parity2_uuid
        parity2_uuid=$(blkid -s UUID -o value "$parity2_resolved" 2>/dev/null || true)
        if [[ -n "$parity2_uuid" ]]; then
            fstab_entries+="UUID=$parity2_uuid $PARITY2_MOUNT ext4 defaults,nofail 0 2\n"
        else
            log_warning "No UUID found for $PARITY2_DISK (or its partitions), skipping fstab entry"
        fi
    fi

    # Add mergerfs mount
    local source_mounts=$(IFS=:; echo "${MOUNT_POINTS[*]}")
    fstab_entries+="$source_mounts $MOUNT_POINT fuse.mergerfs defaults,allow_other,use_ino,cache.files=partial,dropcacheonclose=true,category.create=mfs,moveonenospc=true,minfreespace=50G,fsname=mergerfs 0 0\n"

    if [[ "$DRY_RUN" == false ]]; then
        if grep -q "mergerfs + SnapRAID configuration" /etc/fstab; then
            log_warning "Existing mergerfs + SnapRAID entries found in /etc/fstab"
            log_warning "Skipping fstab modification to avoid duplicates"
            log_warning "Please review /etc/fstab manually if you need to update it"
        else
            echo -e "\n# mergerfs + SnapRAID configuration" >> /etc/fstab
            echo -e "$fstab_entries" >> /etc/fstab
        fi
    else
        log_info "Would add to /etc/fstab:"
        echo -e "$fstab_entries"
    fi

    log_success "fstab configured"
}

# Create SnapRAID configuration
create_snapraid_config() {
    log_info "Creating SnapRAID configuration"
    backup_config "$SNAPRAID_CONF"

    local config="# SnapRAID configuration file\n"
    config+="# Generated by setup script on $(date)\n\n"

    # Parity files
    config+="# Parity location(s)\n"
    config+="parity $PARITY1_MOUNT/snapraid.parity\n"
    if [[ -n "$PARITY2_DISK" ]]; then
        config+="2-parity $PARITY2_MOUNT/snapraid.2-parity\n"
    fi
    config+="\n"

    # Content files (stored on multiple disks for redundancy)
    config+="# Content file locations (multiple copies for redundancy)\n"
    config+="content /var/snapraid/snapraid.content\n"

    local content_count=0
    for i in "${!MOUNT_POINTS[@]}"; do
        if [[ $content_count -lt $SNAPRAID_CONTENT_FILES ]]; then
            config+="content ${MOUNT_POINTS[$i]}/.snapraid.content\n"
            content_count=$((content_count + 1))
        fi
    done
    config+="\n"

    # Data disks
    config+="# Data disks\n"
    for i in "${!MOUNT_POINTS[@]}"; do
        config+="disk d$((i+1)) ${MOUNT_POINTS[$i]}\n"
    done
    config+="\n"

    # Excludes
    config+="# Exclude patterns\n"
    config+="exclude *.unrecoverable\n"
    config+="exclude /tmp/\n"
    config+="exclude /lost+found/\n"
    config+="exclude *.!sync\n"
    config+="exclude .AppleDouble\n"
    config+="exclude ._AppleDouble\n"
    config+="exclude .DS_Store\n"
    config+="exclude .Thumbs.db\n"
    config+="exclude .fseventsd\n"
    config+="exclude .Spotlight-V100\n"
    config+="exclude .TemporaryItems\n"
    config+="exclude .Trashes\n"
    config+="\n"

    # Block size (larger for photo files)
    config+="# Block size (256 KiB is optimal for large files like photos)\n"
    config+="block_size 256\n"
    config+="\n"

    # Hash algorithm
    config+="# Hash algorithm\n"
    config+="hashsize 16\n"
    config+="\n"

    # Auto-save
    config+="# Auto-save state every 10 GB\n"
    config+="autosave 10\n"
    config+="\n"

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p /var/snapraid
        echo -e "$config" > "$SNAPRAID_CONF"
    else
        log_info "Would create $SNAPRAID_CONF with:"
        echo -e "$config"
    fi

    log_success "SnapRAID configuration created"
}

# Mount all filesystems
mount_filesystems() {
    log_info "Mounting filesystems..."

    if [[ "$DRY_RUN" == false ]]; then
        mount -a
    fi

    log_success "Filesystems mounted"
}

# Set permissions for Immich
set_permissions() {
    log_info "Setting permissions for Immich container"

    echo -e "${YELLOW}Enter the UID for Immich user [default: 1000]:${NC}"
    read -r immich_uid
    immich_uid="${immich_uid:-1000}"

    echo -e "${YELLOW}Enter the GID for Immich user [default: 1000]:${NC}"
    read -r immich_gid
    immich_gid="${immich_gid:-1000}"

    if [[ "$DRY_RUN" == false ]]; then
        chown -R "$immich_uid:$immich_gid" "$MOUNT_POINT"
        chmod -R 755 "$MOUNT_POINT"
    fi

    log_success "Permissions set (UID: $immich_uid, GID: $immich_gid)"
}

# Install automation scripts
install_automation_scripts() {
    log_info "Installing automation scripts..."

    local script_dir="/usr/local/bin"

    # Copy sync script
    if [[ -f "./snapraid-sync.sh" ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            cp ./snapraid-sync.sh "$script_dir/"
            chmod +x "$script_dir/snapraid-sync.sh"
        fi
        log_success "Installed snapraid-sync.sh"
    else
        log_warning "snapraid-sync.sh not found in current directory"
    fi

    # Copy diff script
    if [[ -f "./snapraid-diff.sh" ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            cp ./snapraid-diff.sh "$script_dir/"
            chmod +x "$script_dir/snapraid-diff.sh"
        fi
        log_success "Installed snapraid-diff.sh"
    fi

    echo ""
}

# Install systemd services
install_systemd_services() {
    log_info "Installing systemd services and timers..."

    local systemd_dir="/etc/systemd/system"

    # Install service files
    for service_file in snapraid-sync.service snapraid-scrub.service snapraid-sync.timer snapraid-scrub.timer; do
        if [[ -f "./$service_file" ]]; then
            if [[ "$DRY_RUN" == false ]]; then
                cp "./$service_file" "$systemd_dir/"
            fi
            log_success "Installed $service_file"
        else
            log_warning "$service_file not found in current directory"
        fi
    done

    if [[ "$DRY_RUN" == false ]]; then
        systemctl daemon-reload

        # Enable timers
        echo -e "${YELLOW}Enable automatic sync timer? (yes/no):${NC}"
        read -r enable_sync
        if [[ "$enable_sync" == "yes" ]]; then
            systemctl enable snapraid-sync.timer
            systemctl start snapraid-sync.timer
            log_success "Sync timer enabled and started"
        fi

        echo -e "${YELLOW}Enable automatic scrub timer? (yes/no):${NC}"
        read -r enable_scrub
        if [[ "$enable_scrub" == "yes" ]]; then
            systemctl enable snapraid-scrub.timer
            systemctl start snapraid-scrub.timer
            log_success "Scrub timer enabled and started"
        fi
    fi

    echo ""
}

# Run initial sync
initial_sync() {
    echo -e "${YELLOW}Run initial SnapRAID sync now? (yes/no):${NC}"
    read -r run_sync

    if [[ "$run_sync" == "yes" ]] && [[ "$DRY_RUN" == false ]]; then
        log_info "Running initial SnapRAID sync..."
        snapraid sync
        log_success "Initial sync completed"
    fi
}

# Generate documentation
generate_docs() {
    log_info "Generating documentation..."

    local readme="/root/mergerfs-snapraid-setup-README.txt"

    cat > "$readme" << EOF
mergerfs + SnapRAID Setup Summary
Generated: $(date)

CONFIGURATION
=============

Data Disks:
$(for i in "${!DATA_DISKS[@]}"; do echo "  ${DATA_DISKS[$i]} -> ${MOUNT_POINTS[$i]}"; done)

Parity Disks:
  Parity 1: $PARITY1_DISK -> $PARITY1_MOUNT
$(if [[ -n "$PARITY2_DISK" ]]; then echo "  Parity 2: $PARITY2_DISK -> $PARITY2_MOUNT"; fi)

mergerfs Pool: $MOUNT_POINT

MANUAL COMMANDS
===============

Sync (update parity):
  sudo snapraid sync

Sync with diff report:
  sudo /usr/local/bin/snapraid-sync.sh

Check status:
  sudo snapraid status

Scrub (verify data):
  sudo snapraid scrub

Check differences before sync:
  sudo snapraid diff

Fix corrupted files:
  sudo snapraid fix

List all files:
  sudo snapraid list

RECOVERY PROCEDURES
===================

1. Single disk failure:
   - Replace the failed disk
   - Mount it at the original location
   - Run: sudo snapraid fix -d <disk_name>

2. Check specific files:
   - Run: sudo snapraid fix -f <file_path>

3. After multiple deletions:
   - Review diff output carefully
   - If legitimate, proceed with sync
   - If suspicious, investigate before syncing

MAINTENANCE
===========

Daily: Automatic sync (if enabled via timer)
Weekly: Automatic scrub (if enabled via timer)
Monthly: Review logs in /var/log/snapraid/

Check timer status:
  sudo systemctl status snapraid-sync.timer
  sudo systemctl status snapraid-scrub.timer

View recent sync logs:
  sudo journalctl -u snapraid-sync.service

IMPORTANT NOTES
===============

- SnapRAID is NOT real-time backup
- Always run 'snapraid sync' after significant changes
- Review 'snapraid diff' before syncing if many files deleted
- Keep at least one content file copy working for recovery
- Consider off-site backups for critical data
- Test recovery procedures periodically

CONFIGURATION FILES
===================

SnapRAID config: /etc/snapraid.conf
Sync script: /usr/local/bin/snapraid-sync.sh
Diff script: /usr/local/bin/snapraid-diff.sh
Logs: /var/log/snapraid/

EOF

    log_success "Documentation generated: $readme"
    echo ""
}

# Main setup function
main() {
    log_info "Starting mergerfs + SnapRAID setup"
    log_info "Log file: $SETUP_LOG"
    echo ""

    # Pre-flight checks
    detect_disks

    # Interactive configuration
    select_data_disks
    select_parity_disks
    configure_mount_points

    # Display and confirm
    display_summary
    confirm_setup

    # Execute setup
    install_packages
    setup_fstab
    create_snapraid_config
    mount_filesystems
    set_permissions
    install_automation_scripts
    install_systemd_services

    # Post-setup
    initial_sync
    generate_docs

    echo ""
    log_success "Setup completed successfully!"
    echo ""
    echo -e "${GREEN}Next steps:${NC}"
    echo "1. Review the configuration at: $SNAPRAID_CONF"
    echo "2. Check mounted filesystems: df -h"
    echo "3. Review documentation: cat /root/mergerfs-snapraid-setup-README.txt"
    echo "4. Configure Immich to use: $MOUNT_POINT"
    echo "5. Monitor first sync: journalctl -fu snapraid-sync.service"
    echo ""
}

# Run main function
main "$@"
