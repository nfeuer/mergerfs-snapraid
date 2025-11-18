#!/bin/bash

#############################################################################
# SnapRAID Diff Report Script
#
# Generates a detailed report of changes since last sync
# Useful for reviewing changes before running a sync
#
# Usage: sudo /usr/local/bin/snapraid-diff.sh
#############################################################################

set -euo pipefail

# Configuration
SNAPRAID_BIN="/usr/bin/snapraid"
SNAPRAID_CONF="/etc/snapraid.conf"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

# Check if SnapRAID is installed
if [[ ! -x "$SNAPRAID_BIN" ]]; then
    echo -e "${RED}Error: SnapRAID not found at $SNAPRAID_BIN${NC}"
    exit 1
fi

# Check if config exists
if [[ ! -f "$SNAPRAID_CONF" ]]; then
    echo -e "${RED}Error: SnapRAID config not found at $SNAPRAID_CONF${NC}"
    exit 1
fi

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}SnapRAID Diff Report${NC}"
echo -e "${BLUE}=========================================${NC}"
echo -e "${CYAN}Generated: $(date)${NC}"
echo ""

# Get status
echo -e "${YELLOW}Current Status:${NC}"
echo -e "${CYAN}----------------------------------------${NC}"
$SNAPRAID_BIN status | head -20
echo ""

# Run diff
echo -e "${YELLOW}Changes Since Last Sync:${NC}"
echo -e "${CYAN}----------------------------------------${NC}"

DIFF_OUTPUT=$($SNAPRAID_BIN diff 2>&1 || true)

# Parse and colorize output
echo "$DIFF_OUTPUT" | while IFS= read -r line; do
    if echo "$line" | grep -q "equal.*added"; then
        echo -e "${GREEN}$line${NC}"
    elif echo "$line" | grep -q "equal.*removed"; then
        echo -e "${RED}$line${NC}"
    elif echo "$line" | grep -q "equal.*updated"; then
        echo -e "${YELLOW}$line${NC}"
    elif echo "$line" | grep -q "equal.*moved"; then
        echo -e "${BLUE}$line${NC}"
    elif echo "$line" | grep -q "equal.*copied"; then
        echo -e "${MAGENTA}$line${NC}"
    elif echo "$line" | grep -qi "warning\|error"; then
        echo -e "${RED}$line${NC}"
    else
        echo "$line"
    fi
done

echo ""

# Parse summary
ADDED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= added)' | head -1 || echo "0")
REMOVED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= removed)' | head -1 || echo "0")
UPDATED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= updated)' | head -1 || echo "0")
MOVED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= moved)' | head -1 || echo "0")
COPIED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= copied)' | head -1 || echo "0")

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}=========================================${NC}"
echo -e "${GREEN}Added:${NC}   $ADDED files"
echo -e "${RED}Removed:${NC} $REMOVED files"
echo -e "${YELLOW}Updated:${NC} $UPDATED files"
echo -e "${BLUE}Moved:${NC}   $MOVED files"
echo -e "${MAGENTA}Copied:${NC}  $COPIED files"
echo ""

TOTAL_CHANGES=$((ADDED + REMOVED + UPDATED + MOVED + COPIED))

if [[ $TOTAL_CHANGES -eq 0 ]]; then
    echo -e "${GREEN}✓ No changes detected - array is in sync${NC}"
    echo ""
    exit 0
fi

# Warnings
if [[ $REMOVED -gt 100 ]]; then
    echo -e "${RED}⚠ WARNING: Large number of deletions detected!${NC}"
    echo -e "${YELLOW}  Please verify this is expected before syncing.${NC}"
    echo -e "${YELLOW}  This could indicate:${NC}"
    echo -e "${YELLOW}    - Accidental mass deletion${NC}"
    echo -e "${YELLOW}    - Unmounted drive${NC}"
    echo -e "${YELLOW}    - File system issue${NC}"
    echo ""
fi

if [[ $UPDATED -gt 5000 ]]; then
    echo -e "${YELLOW}⚠ NOTE: Large number of updates detected${NC}"
    echo -e "${YELLOW}  Sync may take considerable time.${NC}"
    echo ""
fi

# Check for unmounted disks
if echo "$DIFF_OUTPUT" | grep -qi "WARNING.*not mounted\|WARNING.*not accessible"; then
    echo -e "${RED}⚠ CRITICAL: One or more disks appear unmounted!${NC}"
    echo -e "${RED}  Do NOT sync until issue is resolved.${NC}"
    echo ""
    exit 1
fi

echo -e "${CYAN}To proceed with sync, run:${NC}"
echo -e "  ${GREEN}sudo snapraid sync${NC}"
echo -e "${CYAN}Or use the automated sync script:${NC}"
echo -e "  ${GREEN}sudo /usr/local/bin/snapraid-sync.sh${NC}"
echo ""
