#!/bin/bash
#
# Archive Pre-VRF Card Distribution Data
# =======================================
# This script archives card distribution data from before the VRF shuffle fix
# was deployed on May 1st, 2026 (pokerchain v0.1.70).
#
# The pre-VRF shuffle had bias issues, making distribution stats invalid.
# This script:
# 1. Backs up the current database
# 2. Archives pre-VRF data to separate tables
# 3. Deletes pre-VRF data from active tables
# 4. Resets and recalculates card distribution stats
#
# Usage: ./scripts/archive_pre_vrf.sh [--dry-run] [--cutoff-date YYYY-MM-DD]
#

set -euo pipefail

# Configuration
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-indexer}"
DB_NAME="${DB_NAME:-poker_indexer}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"

# VRF deployment date (May 1st, 2026)
DEFAULT_CUTOFF="2026-05-01"
CUTOFF_DATE="${DEFAULT_CUTOFF}"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --cutoff-date)
            CUTOFF_DATE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--cutoff-date YYYY-MM-DD]"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

run_sql() {
    local sql="$1"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would execute: $sql"
    else
        PGPASSWORD="${DB_PASSWORD:-}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$sql"
    fi
}

run_sql_query() {
    local sql="$1"
    PGPASSWORD="${DB_PASSWORD:-}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "$sql"
}

echo "============================================"
echo "Archive Pre-VRF Card Distribution Data"
echo "============================================"
echo ""
echo "Database: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
echo "Cutoff Date: $CUTOFF_DATE (data before this will be archived)"
echo "Dry Run: $DRY_RUN"
echo ""

if [ "$DRY_RUN" = true ]; then
    log_warn "Running in DRY-RUN mode - no changes will be made"
fi

# Step 0: Check connection
log_info "Checking database connection..."
if ! PGPASSWORD="${DB_PASSWORD:-}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" > /dev/null 2>&1; then
    log_error "Cannot connect to database. Check credentials and connection."
    exit 1
fi
log_info "Database connection OK"

# Step 1: Show current stats
log_info "Current data statistics:"
echo ""
echo "=== Pre-VRF Data (to be archived) ==="
PRE_VRF_HANDS=$(run_sql_query "SELECT COUNT(*) FROM poker_hands WHERE indexed_at < '$CUTOFF_DATE';")
PRE_VRF_RESULTS=$(run_sql_query "SELECT COUNT(*) FROM hand_results WHERE indexed_at < '$CUTOFF_DATE';")
PRE_VRF_CARDS=$(run_sql_query "SELECT COUNT(*) FROM revealed_cards WHERE indexed_at < '$CUTOFF_DATE';")
echo "  poker_hands:    $PRE_VRF_HANDS"
echo "  hand_results:   $PRE_VRF_RESULTS"
echo "  revealed_cards: $PRE_VRF_CARDS"
echo ""

echo "=== Post-VRF Data (to keep) ==="
POST_VRF_HANDS=$(run_sql_query "SELECT COUNT(*) FROM poker_hands WHERE indexed_at >= '$CUTOFF_DATE';")
POST_VRF_RESULTS=$(run_sql_query "SELECT COUNT(*) FROM hand_results WHERE indexed_at >= '$CUTOFF_DATE';")
POST_VRF_CARDS=$(run_sql_query "SELECT COUNT(*) FROM revealed_cards WHERE indexed_at >= '$CUTOFF_DATE';")
echo "  poker_hands:    $POST_VRF_HANDS"
echo "  hand_results:   $POST_VRF_RESULTS"
echo "  revealed_cards: $POST_VRF_CARDS"
echo ""

# Confirm before proceeding
if [ "$DRY_RUN" = false ]; then
    read -p "Proceed with archive? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "Aborted by user"
        exit 0
    fi
fi

# Step 2: Create backup
log_info "Step 1/6: Creating database backup..."
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/poker_indexer_pre_vrf_cleanup_$(date +%Y%m%d_%H%M%S).sql"
if [ "$DRY_RUN" = false ]; then
    PGPASSWORD="${DB_PASSWORD:-}" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" > "$BACKUP_FILE"
    log_info "Backup saved to: $BACKUP_FILE"
else
    log_info "[DRY-RUN] Would save backup to: $BACKUP_FILE"
fi

# Step 3: Create archive tables
log_info "Step 2/6: Creating archive tables..."
run_sql "CREATE TABLE IF NOT EXISTS archived_poker_hands AS SELECT * FROM poker_hands WHERE indexed_at < '$CUTOFF_DATE' LIMIT 0;"
run_sql "CREATE TABLE IF NOT EXISTS archived_hand_results AS SELECT * FROM hand_results WHERE indexed_at < '$CUTOFF_DATE' LIMIT 0;"
run_sql "CREATE TABLE IF NOT EXISTS archived_revealed_cards AS SELECT * FROM revealed_cards WHERE indexed_at < '$CUTOFF_DATE' LIMIT 0;"

# Step 4: Copy data to archive tables
log_info "Step 3/6: Copying pre-VRF data to archive tables..."
run_sql "INSERT INTO archived_poker_hands SELECT * FROM poker_hands WHERE indexed_at < '$CUTOFF_DATE';"
run_sql "INSERT INTO archived_hand_results SELECT * FROM hand_results WHERE indexed_at < '$CUTOFF_DATE';"
run_sql "INSERT INTO archived_revealed_cards SELECT * FROM revealed_cards WHERE indexed_at < '$CUTOFF_DATE';"

# Step 5: Delete pre-VRF data from active tables
log_info "Step 4/6: Deleting pre-VRF data from active tables..."
run_sql "DELETE FROM revealed_cards WHERE indexed_at < '$CUTOFF_DATE';"
run_sql "DELETE FROM hand_results WHERE indexed_at < '$CUTOFF_DATE';"
run_sql "DELETE FROM poker_hands WHERE indexed_at < '$CUTOFF_DATE';"

# Step 6: Reset card distribution stats
log_info "Step 5/6: Resetting card distribution statistics..."
run_sql "UPDATE card_distribution_stats SET total_appearances = 0, community_appearances = 0, hole_card_appearances = 0, last_updated = NOW();"
run_sql "SELECT update_card_distribution_stats();"

# Step 7: Verify results
log_info "Step 6/6: Verifying results..."
echo ""
if [ "$DRY_RUN" = false ]; then
    echo "=== Post-Archive Statistics ==="
    FINAL_HANDS=$(run_sql_query "SELECT COUNT(*) FROM poker_hands;")
    FINAL_CARDS=$(run_sql_query "SELECT COUNT(*) FROM revealed_cards;")
    ARCHIVED_HANDS=$(run_sql_query "SELECT COUNT(*) FROM archived_poker_hands;")
    ARCHIVED_CARDS=$(run_sql_query "SELECT COUNT(*) FROM archived_revealed_cards;")
    echo "  Active poker_hands:    $FINAL_HANDS"
    echo "  Active revealed_cards: $FINAL_CARDS"
    echo "  Archived poker_hands:  $ARCHIVED_HANDS"
    echo "  Archived revealed_cards: $ARCHIVED_CARDS"
    echo ""

    echo "=== Chi-Squared Test (Post-VRF Data Only) ==="
    run_sql_query "SELECT * FROM calculate_chi_squared();"
    echo ""

    echo "=== Top 10 Card Distribution ==="
    run_sql_query "SELECT card, total_appearances, actual_percentage, expected_percentage, deviation_percentage FROM card_frequency_analysis LIMIT 10;"
fi

echo ""
log_info "Archive complete!"
echo ""
echo "Summary:"
echo "  - Pre-VRF data archived to: archived_poker_hands, archived_hand_results, archived_revealed_cards"
echo "  - Active tables now contain only post-VRF data"
echo "  - Card distribution stats recalculated"
if [ "$DRY_RUN" = false ]; then
    echo "  - Backup saved to: $BACKUP_FILE"
fi
