#!/bin/bash

#############################################################################
# SnapRAID Sync Automation Script
#
# This script performs a SnapRAID sync with safety checks:
# - Pre-sync diff report
# - Deletion threshold warnings
# - Email notifications
# - Detailed logging
#
# Usage: sudo /usr/local/bin/snapraid-sync.sh
#############################################################################

set -euo pipefail

# Configuration
SNAPRAID_BIN="/usr/bin/snapraid"
SNAPRAID_CONF="/etc/snapraid.conf"
LOG_DIR="/var/log/snapraid"
LOG_FILE="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/var/run/snapraid-sync.lock"

# Thresholds
DELETE_THRESHOLD=500  # Abort if more than this many files deleted
UPDATE_THRESHOLD=10000  # Warning if more than this many files updated

# Email settings (configure these)
EMAIL_ENABLED=false
EMAIL_TO="admin@example.com"
EMAIL_FROM="snapraid@$(hostname)"
EMAIL_SUBJECT_PREFIX="[SnapRAID]"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Logging functions
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "$LOG_FILE"
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

# Send email notification
send_email() {
    local subject="$1"
    local body="$2"

    if [[ "$EMAIL_ENABLED" == true ]]; then
        echo -e "$body" | mail -s "$EMAIL_SUBJECT_PREFIX $subject" -r "$EMAIL_FROM" "$EMAIL_TO"
    fi
}

# Acquire exclusive lock (atomic, no race condition)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log_error "Another SnapRAID operation is already running (could not acquire lock)"
    exit 1
fi

# Check if SnapRAID is installed
if [[ ! -x "$SNAPRAID_BIN" ]]; then
    log_error "SnapRAID not found at $SNAPRAID_BIN"
    send_email "Sync Failed - SnapRAID Not Found" "SnapRAID binary not found at $SNAPRAID_BIN"
    exit 1
fi

# Check if config exists
if [[ ! -f "$SNAPRAID_CONF" ]]; then
    log_error "SnapRAID config not found at $SNAPRAID_CONF"
    send_email "Sync Failed - Config Not Found" "SnapRAID config not found at $SNAPRAID_CONF"
    exit 1
fi

log_info "========================================="
log_info "SnapRAID Sync Starting"
log_info "========================================="
log_info "Timestamp: $(date)"
log_info "Config: $SNAPRAID_CONF"
log_info "Log: $LOG_FILE"
log_info ""

# Run SMART check
log_info "Running SMART health check on all disks..."
SMART_OUTPUT=$($SNAPRAID_BIN smart 2>&1 || true)
echo "$SMART_OUTPUT" >> "$LOG_FILE"

if echo "$SMART_OUTPUT" | grep -qi "fail\|error"; then
    log_error "SMART check detected failing disk!"
    log_warning "$SMART_OUTPUT"
    send_email "URGENT: Disk Failure Detected" "SMART check detected a failing disk:\n\n$SMART_OUTPUT\n\nSync aborted."
    exit 1
fi
log_success "SMART check passed"
echo ""

# Get disk status
log_info "Checking disk status..."
STATUS_OUTPUT=$($SNAPRAID_BIN status 2>&1 || true)
echo "$STATUS_OUTPUT" >> "$LOG_FILE"
echo ""

# Run diff to see what has changed
log_info "Running pre-sync diff analysis..."
DIFF_OUTPUT=$($SNAPRAID_BIN diff 2>&1 || true)
echo "$DIFF_OUTPUT" >> "$LOG_FILE"

# Parse diff output (each stat is on its own line, e.g. "      35 added")
ADDED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= added)' | head -1 || echo "0")
REMOVED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= removed)' | head -1 || echo "0")
UPDATED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= updated)' | head -1 || echo "0")
MOVED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= moved)' | head -1 || echo "0")
COPIED=$(echo "$DIFF_OUTPUT" | grep -oP '\d+(?= copied)' | head -1 || echo "0")
ADDED="${ADDED:-0}"
REMOVED="${REMOVED:-0}"
UPDATED="${UPDATED:-0}"
MOVED="${MOVED:-0}"
COPIED="${COPIED:-0}"

log_info "Changes detected:"
log_info "  Added: $ADDED files"
log_info "  Removed: $REMOVED files"
log_info "  Updated: $UPDATED files"
log_info "  Moved: $MOVED files"
log_info "  Copied: $COPIED files"
echo ""

# Check if there are any changes
TOTAL_CHANGES=$((ADDED + REMOVED + UPDATED + MOVED + COPIED))
if [[ $TOTAL_CHANGES -eq 0 ]]; then
    log_info "No changes detected, sync not needed"
    send_email "Sync Skipped - No Changes" "No changes detected during diff check."
    exit 0
fi

# Check deletion threshold
if [[ $REMOVED -gt $DELETE_THRESHOLD ]]; then
    log_error "DELETION THRESHOLD EXCEEDED!"
    log_error "Found $REMOVED deleted files (threshold: $DELETE_THRESHOLD)"
    log_error "This could indicate:"
    log_error "  - Accidental mass deletion"
    log_error "  - Unmounted drive"
    log_error "  - File system corruption"
    log_error ""
    log_error "Please review the changes manually and run sync manually if correct."
    log_error "Command: sudo $SNAPRAID_BIN sync"

    send_email "Sync Aborted - Deletion Threshold Exceeded" \
        "Deletion threshold exceeded!\n\nRemoved files: $REMOVED\nThreshold: $DELETE_THRESHOLD\n\nDiff output:\n$DIFF_OUTPUT\n\nPlease review manually."

    exit 1
fi

# Warning for large updates
if [[ $UPDATED -gt $UPDATE_THRESHOLD ]]; then
    log_warning "Large number of updates detected: $UPDATED files"
fi

# Check for unmounted disks
log_info "Checking for unmounted disks..."
if echo "$DIFF_OUTPUT" | grep -qi "WARNING.*not mounted\|WARNING.*not accessible"; then
    log_error "One or more disks appear to be unmounted!"
    log_error "$DIFF_OUTPUT"
    send_email "Sync Aborted - Disk Not Mounted" \
        "One or more disks appear to be unmounted.\n\nDiff output:\n$DIFF_OUTPUT"
    exit 1
fi
log_success "All disks appear to be mounted"
echo ""

# Perform the sync
log_info "Starting SnapRAID sync..."
log_info "This may take a while depending on the number of changes..."
echo ""

SYNC_START=$(date +%s)

if $SNAPRAID_BIN sync 2>&1 | tee -a "$LOG_FILE"; then
    SYNC_END=$(date +%s)
    SYNC_DURATION=$((SYNC_END - SYNC_START))
    SYNC_DURATION_MIN=$((SYNC_DURATION / 60))

    log_success "========================================="
    log_success "Sync completed successfully!"
    log_success "========================================="
    log_success "Duration: ${SYNC_DURATION_MIN} minutes"
    log_success "Added: $ADDED files"
    log_success "Removed: $REMOVED files"
    log_success "Updated: $UPDATED files"
    log_success "Moved: $MOVED files"
    log_success "Copied: $COPIED files"
    log_success ""

    # Send success email
    send_email "Sync Completed Successfully" \
        "SnapRAID sync completed successfully!\n\nDuration: ${SYNC_DURATION_MIN} minutes\nAdded: $ADDED\nRemoved: $REMOVED\nUpdated: $UPDATED\nMoved: $MOVED\nCopied: $COPIED\n\nLog: $LOG_FILE"

    # Rotate old logs (keep last 30)
    log_info "Rotating old log files..."
    find "$LOG_DIR" -name "sync-*.log" -type f -mtime +30 -delete

    exit 0
else
    SYNC_END=$(date +%s)
    SYNC_DURATION=$((SYNC_END - SYNC_START))

    log_error "========================================="
    log_error "Sync FAILED!"
    log_error "========================================="
    log_error "Duration: $SYNC_DURATION seconds"
    log_error "Check log file for details: $LOG_FILE"
    log_error ""

    # Get last 50 lines of log for email
    LOG_TAIL=$(tail -50 "$LOG_FILE")

    send_email "Sync FAILED" \
        "SnapRAID sync failed after $SYNC_DURATION seconds.\n\nLast 50 lines of log:\n\n$LOG_TAIL\n\nFull log: $LOG_FILE"

    exit 1
fi
