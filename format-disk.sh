#!/bin/bash

#############################################################################
# Disk Formatting Helper Script
#
# Safely format disks for use with mergerfs + SnapRAID
# WARNING: This will ERASE ALL DATA on the selected disk!
#
# Usage: sudo ./format-disk.sh
#############################################################################

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}Disk Formatting Helper${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
echo -e "${RED}WARNING: This will ERASE ALL DATA on selected disk!${NC}"
echo ""

# Display available disks
echo -e "${YELLOW}Available Disks:${NC}"
echo "----------------------------------------"
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL | grep -v "loop\|ram"
echo "----------------------------------------"
echo ""

# Get disk selection
echo -e "${YELLOW}Enter the disk to format (e.g., sda, sdb, nvme0n1):${NC}"
read -r disk_name

DISK="/dev/$disk_name"

# Validate disk exists
if [[ ! -b "$DISK" ]]; then
    echo -e "${RED}Error: $DISK is not a valid block device${NC}"
    exit 1
fi

# Show disk information
echo ""
echo -e "${BLUE}Disk Information:${NC}"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK"
echo ""

# Check if disk or any of its partitions are mounted
if mount | grep -q "^${DISK}[[:space:]p0-9]"; then
    echo -e "${RED}Error: $DISK or one of its partitions is currently mounted!${NC}"
    echo "Please unmount all partitions first:"
    mount | grep "^${DISK}" | awk '{print "  sudo umount " $1}'
    exit 1
fi

# Get disk size
DISK_SIZE=$(lsblk -d -n -o SIZE "$DISK")

# Final confirmation
echo -e "${RED}=========================================${NC}"
echo -e "${RED}FINAL WARNING${NC}"
echo -e "${RED}=========================================${NC}"
echo -e "${RED}Disk:${NC} $DISK"
echo -e "${RED}Size:${NC} $DISK_SIZE"
echo -e "${RED}This will PERMANENTLY ERASE ALL DATA!${NC}"
echo -e "${RED}=========================================${NC}"
echo ""
echo -e "${YELLOW}Type 'YES' (in capital letters) to continue:${NC}"
read -r confirmation

if [[ "$confirmation" != "YES" ]]; then
    echo -e "${GREEN}Operation cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}Step 1: Wiping existing partition table...${NC}"
wipefs -a "$DISK"

echo -e "${BLUE}Step 2: Creating new GPT partition table...${NC}"
parted -s "$DISK" mklabel gpt

echo -e "${BLUE}Step 3: Creating single partition...${NC}"
parted -s "$DISK" mkpart primary ext4 0% 100%

# Determine partition name
if [[ "$disk_name" =~ nvme ]]; then
    PARTITION="${DISK}p1"
else
    PARTITION="${DISK}1"
fi

# Wait for partition to be created
sleep 2

echo -e "${BLUE}Step 4: Formatting partition as ext4...${NC}"
echo "This may take several minutes for large drives..."
mkfs.ext4 -F -L "snapraid-disk" "$PARTITION"

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}Disk formatted successfully!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "${BLUE}Partition:${NC} $PARTITION"
echo -e "${BLUE}Filesystem:${NC} ext4"
echo -e "${BLUE}UUID:${NC} $(blkid -s UUID -o value "$PARTITION")"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Create a mount point: sudo mkdir /mnt/disk1"
echo "2. Mount the disk: sudo mount $PARTITION /mnt/disk1"
echo "3. Run the setup script: sudo ./setup-mergerfs-snapraid.sh"
echo ""
