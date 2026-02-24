#!/bin/bash

###############################################################################
# Cron Job Setup for Continuous Indexing
#
# This script sets up a cron job to run the indexer every 5 minutes,
# ensuring new blocks are continuously indexed.
#
# Usage:
#   ./setup-cron.sh <node_rpc_url>
#
# Example:
#   ./setup-cron.sh http://node1.block52.xyz:26657
#
###############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Helper functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${CYAN}==>${NC} ${BLUE}$1${NC}\n"; }

# Check if node RPC URL provided
if [ -z "$1" ]; then
    log_error "Node RPC URL required"
    echo "Usage: $0 <node_rpc_url>"
    echo "Example: $0 http://node1.block52.xyz:26657"
    exit 1
fi

NODE_RPC="$1"

# Welcome banner
clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║     Poker Indexer                                        ║
║     Continuous Indexing Setup (Cron)                     ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF

echo ""
log_info "Setting up cron job for continuous indexing"
echo ""

# Get current directory
INDEXER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_info "Indexer directory: $INDEXER_DIR"

# Get database configuration
read -p "Database host [localhost]: " DB_HOST
DB_HOST=${DB_HOST:-localhost}

read -p "Database port [5432]: " DB_PORT
DB_PORT=${DB_PORT:-5432}

read -p "Database user [poker]: " DB_USER
DB_USER=${DB_USER:-poker}

read -sp "Database password [poker_indexer_dev]: " DB_PASS
echo ""
DB_PASS=${DB_PASS:-poker_indexer_dev}

read -p "Database name [poker_hands]: " DB_NAME
DB_NAME=${DB_NAME:-poker_hands}

read -p "Cron interval in minutes [5]: " CRON_INTERVAL
CRON_INTERVAL=${CRON_INTERVAL:-5}

# Confirm configuration
echo ""
log_step "Configuration Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Node RPC:       $NODE_RPC"
echo "  Indexer Dir:    $INDEXER_DIR"
echo "  DB Host:        $DB_HOST"
echo "  DB Port:        $DB_PORT"
echo "  DB User:        $DB_USER"
echo "  DB Name:        $DB_NAME"
echo "  Cron Interval:  Every $CRON_INTERVAL minutes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Continue with this configuration? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_error "Setup cancelled"
    exit 1
fi

# Check if indexer binary exists
if [ ! -f "$INDEXER_DIR/indexer" ]; then
    log_warning "Indexer binary not found. Building..."
    cd "$INDEXER_DIR"
    go build -o indexer ./cmd/indexer
    if [ $? -eq 0 ]; then
        log_success "Indexer built successfully"
    else
        log_error "Failed to build indexer"
        exit 1
    fi
fi

# Create log directory
LOG_DIR="$INDEXER_DIR/logs"
mkdir -p "$LOG_DIR"
log_info "Log directory: $LOG_DIR"

# Create indexer wrapper script
WRAPPER_SCRIPT="$INDEXER_DIR/run-indexer-cron.sh"
cat > "$WRAPPER_SCRIPT" << EOF
#!/bin/bash
# Auto-generated indexer cron wrapper script
# Do not edit manually - regenerate with setup-cron.sh

LOG_FILE="$LOG_DIR/indexer-\$(date +%Y%m%d).log"

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting indexer..." >> "\$LOG_FILE"

# Get the last indexed block from database
LAST_BLOCK=\$(PGPASSWORD="$DB_PASS" psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT COALESCE(MAX(block_height), 0) FROM poker_hands;" 2>/dev/null | xargs)

if [ -z "\$LAST_BLOCK" ] || [ "\$LAST_BLOCK" = "0" ]; then
    START_BLOCK=1
else
    # Start from next block after last indexed
    START_BLOCK=\$((LAST_BLOCK + 1))
fi

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Last indexed block: \$LAST_BLOCK, starting from: \$START_BLOCK" >> "\$LOG_FILE"

# Run indexer from last block to current
cd "$INDEXER_DIR"
./indexer \\
    -node "$NODE_RPC" \\
    -start \$START_BLOCK \\
    -end 0 \\
    -db-host $DB_HOST \\
    -db-port $DB_PORT \\
    -db-user $DB_USER \\
    -db-pass "$DB_PASS" \\
    -db-name $DB_NAME >> "\$LOG_FILE" 2>&1

EXIT_CODE=\$?
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Indexer finished with exit code: \$EXIT_CODE" >> "\$LOG_FILE"

# Keep only last 30 days of logs
find "$LOG_DIR" -name "indexer-*.log" -mtime +30 -delete

exit \$EXIT_CODE
EOF

chmod +x "$WRAPPER_SCRIPT"
log_success "Created wrapper script: $WRAPPER_SCRIPT"

# Create cron entry
CRON_SCHEDULE="*/$CRON_INTERVAL * * * *"
CRON_ENTRY="$CRON_SCHEDULE $WRAPPER_SCRIPT"

log_step "Setting up cron job"

# Check if cron entry already exists
if crontab -l 2>/dev/null | grep -F "$WRAPPER_SCRIPT" >/dev/null; then
    log_warning "Cron job already exists. Removing old entry..."
    crontab -l 2>/dev/null | grep -v -F "$WRAPPER_SCRIPT" | crontab -
fi

# Add new cron entry
(crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -

if [ $? -eq 0 ]; then
    log_success "Cron job installed successfully"
else
    log_error "Failed to install cron job"
    exit 1
fi

# Final summary
log_step "Setup Complete!"
echo ""
log_success "Continuous indexing is now active"
echo ""
echo "Cron Schedule: Every $CRON_INTERVAL minutes"
echo "Wrapper Script: $WRAPPER_SCRIPT"
echo "Logs Directory: $LOG_DIR"
echo ""

# Show current crontab
log_step "Current Crontab Entries"
crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" || echo "(none)"
echo ""

# Useful commands
log_step "Useful Commands"
echo ""
echo "View cron jobs:"
echo "  crontab -l"
echo ""
echo "View today's indexer log:"
echo "  tail -f $LOG_DIR/indexer-\$(date +%Y%m%d).log"
echo ""
echo "View all logs:"
echo "  ls -lh $LOG_DIR/"
echo ""
echo "Remove cron job:"
echo "  crontab -l | grep -v '$WRAPPER_SCRIPT' | crontab -"
echo ""
echo "Run indexer manually:"
echo "  $WRAPPER_SCRIPT"
echo ""
echo "Test next run (dry run):"
echo "  bash -x $WRAPPER_SCRIPT"
echo ""
