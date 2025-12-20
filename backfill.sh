#!/bin/bash
# Backfill historical blocks from a Pokerchain node
# Usage: ./backfill.sh <node_rpc_url> [start_block] [end_block]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration (can be overridden by environment variables)
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_USER=${DB_USER:-poker}
DB_PASS=${DB_PASS:-poker_indexer_dev}
DB_NAME=${DB_NAME:-poker_hands}
BATCH_SIZE=${BATCH_SIZE:-100}
NODE_API=${NODE_API:-}  # REST API endpoint (derived from RPC if not set)

# Parse arguments
NODE_RPC="${1:-}"
START_BLOCK="${2:-1}"
END_BLOCK="${3:-0}"

print_usage() {
    echo "Poker Hand Distribution Backfill Tool"
    echo ""
    echo "Usage: $0 <node_rpc_url> [start_block] [end_block]"
    echo ""
    echo "Arguments:"
    echo "  node_rpc_url   RPC endpoint (e.g., http://localhost:26657)"
    echo "  start_block    Starting block height (default: 1)"
    echo "  end_block      Ending block height (default: 0 = latest)"
    echo ""
    echo "Environment Variables:"
    echo "  DB_HOST        PostgreSQL host (default: localhost)"
    echo "  DB_PORT        PostgreSQL port (default: 5432)"
    echo "  DB_USER        PostgreSQL user (default: poker)"
    echo "  DB_PASS        PostgreSQL password (default: poker_indexer_dev)"
    echo "  DB_NAME        PostgreSQL database (default: poker_hands)"
    echo "  BATCH_SIZE     Blocks per progress update (default: 100)"
    echo "  NODE_API       REST API endpoint (default: derived from RPC)"
    echo ""
    echo "Examples:"
    echo "  # Backfill all blocks from local node"
    echo "  $0 http://localhost:26657"
    echo ""
    echo "  # Backfill blocks 1000-2000 from remote node"
    echo "  $0 https://rpc.block52.xyz 1000 2000"
    echo ""
    echo "  # Use custom database"
    echo "  DB_HOST=db.example.com DB_PASS=secret $0 http://localhost:26657"
}

if [ -z "$NODE_RPC" ]; then
    print_usage
    exit 1
fi

# Verify node is reachable
echo -e "${YELLOW}Checking node connectivity...${NC}"
if ! curl -s "${NODE_RPC}/status" > /dev/null 2>&1; then
    echo -e "${RED}Error: Cannot connect to node at ${NODE_RPC}${NC}"
    echo "Please verify the node URL is correct and the node is running."
    exit 1
fi

# Get latest block from node
LATEST_BLOCK=$(curl -s "${NODE_RPC}/status" | grep -o '"latest_block_height":"[0-9]*"' | grep -o '[0-9]*')
echo -e "${GREEN}Node connected. Latest block: ${LATEST_BLOCK}${NC}"

# Check if database is running
echo -e "${YELLOW}Checking database connectivity...${NC}"

# Try multiple methods to check DB connectivity
DB_OK=false

# Method 1: Try psql if available
if command -v psql &> /dev/null; then
    if PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1" > /dev/null 2>&1; then
        DB_OK=true
    fi
fi

# Method 2: Try docker exec if psql not available and using localhost
if [ "$DB_OK" = false ] && [ "$DB_HOST" = "localhost" ] || [ "$DB_HOST" = "127.0.0.1" ]; then
    if docker exec poker-indexer-db pg_isready -U "${DB_USER}" -d "${DB_NAME}" > /dev/null 2>&1; then
        DB_OK=true
    fi
fi

# Method 3: Simple TCP check
if [ "$DB_OK" = false ]; then
    if nc -z "${DB_HOST}" "${DB_PORT}" 2>/dev/null || (echo > /dev/tcp/${DB_HOST}/${DB_PORT}) 2>/dev/null; then
        DB_OK=true
    fi
fi

if [ "$DB_OK" = false ]; then
    echo -e "${RED}Error: Cannot connect to PostgreSQL at ${DB_HOST}:${DB_PORT}${NC}"
    echo ""
    echo "Start the database with:"
    echo "  docker compose up -d postgres"
    exit 1
fi
echo -e "${GREEN}Database connected.${NC}"

# Check if indexer binary exists, build if not
INDEXER_BIN="./indexer"
if [ ! -f "$INDEXER_BIN" ]; then
    echo -e "${YELLOW}Building indexer...${NC}"

    # Check if Go is installed
    if ! command -v go &> /dev/null; then
        echo -e "${RED}Error: Go is not installed. Please install Go 1.22+${NC}"
        exit 1
    fi

    # Download dependencies and build
    go mod tidy
    go build -o indexer ./cmd/indexer

    if [ ! -f "$INDEXER_BIN" ]; then
        echo -e "${RED}Error: Failed to build indexer${NC}"
        exit 1
    fi
    echo -e "${GREEN}Indexer built successfully.${NC}"
fi

# Determine end block
if [ "$END_BLOCK" = "0" ]; then
    END_BLOCK="$LATEST_BLOCK"
fi

# Summary before starting
echo ""
echo "=========================================="
echo "  Poker Hand Distribution Backfill"
echo "=========================================="
echo "Node:        ${NODE_RPC}"
echo "Database:    ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "Block Range: ${START_BLOCK} to ${END_BLOCK}"
echo "Total:       $((END_BLOCK - START_BLOCK + 1)) blocks"
echo "=========================================="
echo ""

# Confirm before proceeding for large ranges
BLOCK_COUNT=$((END_BLOCK - START_BLOCK + 1))
if [ "$BLOCK_COUNT" -gt 10000 ]; then
    echo -e "${YELLOW}Warning: This will process ${BLOCK_COUNT} blocks which may take a while.${NC}"
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Run the indexer
echo -e "${GREEN}Starting backfill...${NC}"
echo ""

# Build API args if NODE_API is set
API_ARGS=""
if [ -n "$NODE_API" ]; then
    API_ARGS="-api $NODE_API"
fi

$INDEXER_BIN \
    -node "$NODE_RPC" \
    $API_ARGS \
    -db-host "$DB_HOST" \
    -db-port "$DB_PORT" \
    -db-user "$DB_USER" \
    -db-pass "$DB_PASS" \
    -db-name "$DB_NAME" \
    -start "$START_BLOCK" \
    -end "$END_BLOCK" \
    -batch "$BATCH_SIZE"

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}=========================================="
    echo "  Backfill Complete!"
    echo "==========================================${NC}"
    echo ""
    echo "Run analysis with:"
    echo "  ./run-analysis.sh report"
else
    echo -e "${RED}Backfill failed with exit code ${EXIT_CODE}${NC}"
fi

exit $EXIT_CODE
