# Poker Hand Distribution Indexer

![Go](https://img.shields.io/badge/Go-00ADD8?style=for-the-badge&logo=go&logoColor=white)

Index poker hands from Pokerchain into PostgreSQL for statistical analysis and randomness verification.

## Overview

A standalone Go indexer that fetches poker hand events from any Pokerchain node and stores them in PostgreSQL for statistical analysis.

### Events Tracked

| Event | Description |
|-------|-------------|
| `hand_started` | New hand dealt - captures deck seed and shuffled deck |
| `hand_completed` | Hand finished at showdown - captures revealed cards |

### Analysis Capabilities

- **Card frequency distribution** - Verify each card appears ~1/52 of the time
- **Chi-squared tests** - Statistical test for uniform distribution
- **Suit/Rank distribution** - Check for bias in suits or ranks
- **Deck seed entropy** - Verify block hashes provide unique seeds
- **Time series analysis** - Track distribution over block ranges

## Quick Start

### 1. Start PostgreSQL

```bash
docker compose up -d postgres

# Optional: Start Adminer UI on port 8080
docker compose --profile tools up -d adminer
```

### 2. Start REST API (Optional)

The indexer includes a REST API for querying statistics programmatically:

```bash
# Build the API
go build -o api ./cmd/api

# Run the API
./api
```

API will be available at `http://localhost:8000`. See [API.md](API.md) for full documentation.

### 3. Backfill Historical Blocks

```bash
# Index all blocks from a node
./backfill.sh http://localhost:26657

# Index specific block range
./backfill.sh http://localhost:26657 1000 5000

# Use remote node
./backfill.sh https://rpc.pokerchain.example.com
```

### 4. Run Analysis

```bash
# Quick randomness report
./run-analysis.sh report

# Full analysis
./run-analysis.sh full

# See all commands
./run-analysis.sh help
```

## Backfill Script

The `backfill.sh` script handles everything:

```bash
./backfill.sh <node_rpc_url> [start_block] [end_block]
```

**Arguments:**
- `node_rpc_url` - RPC endpoint (e.g., `http://localhost:26657`)
- `start_block` - Starting block height (default: 1)
- `end_block` - Ending block height (default: 0 = latest)

**Environment Variables:**
- `DB_HOST` - PostgreSQL host (default: localhost)
- `DB_PORT` - PostgreSQL port (default: 5432)
- `DB_USER` - PostgreSQL user (default: poker)
- `DB_PASS` - PostgreSQL password (default: poker_indexer_dev)
- `DB_NAME` - PostgreSQL database (default: poker_hands)

**Examples:**
```bash
# Backfill all blocks from local node
./backfill.sh http://localhost:26657

# Backfill blocks 1000-2000 from remote node
./backfill.sh https://rpc.pokerchain.io 1000 2000

# Use custom database
DB_HOST=db.example.com DB_PASS=secret ./backfill.sh http://localhost:26657
```

## Direct Indexer Usage

You can also run the indexer directly:

```bash
# Build (if not already built)
go build -o indexer ./cmd/indexer

# Run with flags
./indexer \
  -node http://localhost:26657 \
  -start 1 \
  -end 10000 \
  -db-host localhost \
  -db-port 5432 \
  -db-user poker \
  -db-pass poker_indexer_dev \
  -db-name poker_hands
```

## Analysis Commands

| Command | Description |
|---------|-------------|
| `./run-analysis.sh report` | Comprehensive randomness report |
| `./run-analysis.sh summary` | Basic statistics |
| `./run-analysis.sh cards` | Card frequency analysis |
| `./run-analysis.sh outliers` | Cards with >1% deviation |
| `./run-analysis.sh suits` | Suit distribution + chi-squared |
| `./run-analysis.sh ranks` | Rank distribution + chi-squared |
| `./run-analysis.sh chi-squared` | Full chi-squared test |
| `./run-analysis.sh seeds` | Check for duplicate deck seeds |
| `./run-analysis.sh timeline` | Distribution over time |
| `./run-analysis.sh full` | All analyses |

## Understanding Results

### Chi-Squared Test

The chi-squared test compares observed card frequencies to expected uniform distribution:

| Result | Meaning |
|--------|---------|
| `PASS (p > 0.05)` | Distribution is consistent with random |
| `MARGINAL (0.01 < p < 0.05)` | Borderline - may need more data |
| `FAIL (p < 0.01)` | Distribution appears non-random |

### Critical Values (df=51)

- p=0.05: 68.67
- p=0.01: 76.15
- p=0.001: 86.66

### Sample Size Requirements

For statistically significant results:
- Minimum: 100 cards
- Recommended: 1,000+ cards
- High confidence: 10,000+ cards

## Database Schema

### Tables

```sql
-- Hands that started (with deck info)
poker_hands (game_id, hand_number, block_height, deck_seed, deck)

-- Completed hands with results
hand_results (game_id, hand_number, community_cards, winner_count)

-- Individual revealed cards
revealed_cards (game_id, hand_number, card, card_type, position)

-- Aggregated statistics (auto-updated via trigger)
card_distribution_stats (card, rank, suit, total_appearances, ...)
```

### Views

```sql
card_frequency_analysis   -- Card frequency with expected vs actual
rank_distribution        -- Aggregated by rank
suit_distribution        -- Aggregated by suit
seed_entropy_analysis    -- Check for duplicate seeds
```

## Manual Queries

```sql
-- Card frequency
SELECT * FROM card_frequency_analysis ORDER BY total_appearances DESC;

-- Run randomness report
SELECT * FROM generate_randomness_report();

-- Chi-squared test
SELECT * FROM calculate_chi_squared();

-- Check for patterns in first two community cards
SELECT * FROM community_card_sequences;
```

## REST API

The indexer includes a comprehensive REST API for programmatic access to statistics and analysis data.

### Starting the API

```bash
# Build
go build -o api ./cmd/api

# Run
./api
```

API available at `http://localhost:8000`

### Example Requests

```bash
# Health check
curl http://localhost:8000/health

# Get statistics summary
curl http://localhost:8000/api/v1/stats/summary

# Get card frequency distribution
curl http://localhost:8000/api/v1/stats/cards

# Get randomness analysis
curl http://localhost:8000/api/v1/analysis/randomness

# Get player stats
curl http://localhost:8000/api/v1/players/poker1abc.../stats
```

**Full API documentation:** See [API.md](API.md)

## Connect to Database

```bash
# Via psql
PGPASSWORD=poker_indexer_dev psql -h localhost -U poker -d poker_hands

# Via Adminer UI
open http://localhost:8080
# Server: postgres, User: poker, Password: poker_indexer_dev, Database: poker_hands

# Via REST API
curl http://localhost:8000/api/v1/stats/summary
```

## Troubleshooting

### No data appearing
1. Check that the node has poker hand events (`hand_started`, `hand_completed`)
2. Verify the block range contains poker game transactions
3. Run `./run-analysis.sh summary` to see indexed counts

### Statistics not updating
```bash
./run-analysis.sh refresh-stats
```

### Reset database
```bash
docker compose down -v
docker compose up -d postgres
```

### Build errors
```bash
go mod tidy
go build -o indexer ./cmd/indexer
```
