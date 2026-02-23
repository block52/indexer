# Poker Indexer REST API

REST API for querying poker hand statistics and analysis data from the indexer database.

## Quick Start

### 1. Start the Database

```bash
docker compose up -d postgres
```

### 2. Run the API

```bash
# Build
go build -o api ./cmd/api

# Run with default settings
./api

# Or with custom configuration
API_PORT=8000 \
DB_HOST=localhost \
DB_PORT=5432 \
DB_USER=poker \
DB_PASSWORD=poker_indexer_dev \
DB_NAME=poker_hands \
./api
```

The API will be available at `http://localhost:8000`

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `API_PORT` | API server port | `8000` |
| `DB_HOST` | PostgreSQL host | `localhost` |
| `DB_PORT` | PostgreSQL port | `5432` |
| `DB_USER` | PostgreSQL user | `poker` |
| `DB_PASSWORD` | PostgreSQL password | `poker_indexer_dev` |
| `DB_NAME` | Database name | `poker_hands` |
| `CORS_ORIGINS` | CORS allowed origins | `*` |
| `ENVIRONMENT` | Environment mode | `development` |
| `DB_MAX_CONNS` | Max DB connections | `25` |
| `DB_MAX_IDLE` | Max idle DB connections | `5` |

## API Endpoints

### Health Check

#### `GET /health`

Returns service health status.

**Response:**
```json
{
  "status": "healthy",
  "database": "connected",
  "uptime": "2h15m30s"
}
```

---

## Hand Data Endpoints

### `GET /api/v1/hands`

List poker hands with pagination and optional filters.

**Query Parameters:**
- `limit` (int, optional): Results per page (default: 50, max: 1000)
- `offset` (int, optional): Results offset (default: 0)
- `game_id` (string, optional): Filter by game ID
- `start_block` (int, optional): Filter by minimum block height
- `end_block` (int, optional): Filter by maximum block height

**Example:**
```bash
curl "http://localhost:8000/api/v1/hands?limit=10&offset=0"
curl "http://localhost:8000/api/v1/hands?game_id=game123"
curl "http://localhost:8000/api/v1/hands?start_block=1000&end_block=2000"
```

**Response:**
```json
{
  "data": [
    {
      "game_id": "game123",
      "hand_number": 42,
      "block_height": 12345,
      "deck_seed": "abc123...",
      "deck": "AS,KH,QD...",
      "tx_hash": "tx123",
      "created_at": "2024-02-24T10:00:00Z"
    }
  ],
  "pagination": {
    "limit": 50,
    "offset": 0,
    "total": 1234
  }
}
```

### `GET /api/v1/hands/:game_id/:hand_number`

Get detailed information about a specific hand.

**Example:**
```bash
curl "http://localhost:8000/api/v1/hands/game123/42"
```

**Response:**
```json
{
  "game_id": "game123",
  "hand_number": 42,
  "block_height": 12345,
  "deck_seed": "abc123...",
  "deck": "AS,KH,QD...",
  "tx_hash": "tx123",
  "created_at": "2024-02-24T10:00:00Z",
  "result": {
    "game_id": "game123",
    "hand_number": 42,
    "block_height": 12346,
    "community_cards": ["AS", "KH", "QD", "JC", "10S"],
    "winner_count": 2,
    "tx_hash": "tx124",
    "created_at": "2024-02-24T10:05:00Z"
  },
  "revealed_cards": [
    {
      "id": 1,
      "game_id": "game123",
      "hand_number": 42,
      "block_height": 12346,
      "card": "AS",
      "card_type": "community",
      "position": 0,
      "created_at": "2024-02-24T10:05:00Z"
    }
  ]
}
```

### `GET /api/v1/hands/:game_id/:hand_number/cards`

Get all revealed cards for a specific hand.

**Example:**
```bash
curl "http://localhost:8000/api/v1/hands/game123/42/cards"
```

**Response:**
```json
{
  "game_id": "game123",
  "hand_number": 42,
  "cards": [
    {
      "id": 1,
      "game_id": "game123",
      "hand_number": 42,
      "block_height": 12346,
      "card": "AS",
      "card_type": "community",
      "position": 0,
      "created_at": "2024-02-24T10:05:00Z"
    }
  ]
}
```

---

## Statistics Endpoints

### `GET /api/v1/stats/summary`

Get overall statistics summary.

**Example:**
```bash
curl "http://localhost:8000/api/v1/stats/summary"
```

**Response:**
```json
{
  "total_hands": 1234,
  "total_completed_hands": 987,
  "total_revealed_cards": 5432,
  "unique_games": 42,
  "block_height_range": "1-12345",
  "first_indexed_at": "2024-02-01T00:00:00Z",
  "last_indexed_at": "2024-02-24T10:00:00Z"
}
```

### `GET /api/v1/stats/cards`

Get card frequency statistics for all cards.

**Example:**
```bash
curl "http://localhost:8000/api/v1/stats/cards"
```

**Response:**
```json
[
  {
    "card": "AS",
    "rank": "A",
    "suit": "♠",
    "total_appearances": 105,
    "expected_frequency": 1.923,
    "actual_frequency": 1.932,
    "deviation": 0.009,
    "deviation_percent": 0.468
  }
]
```

### `GET /api/v1/stats/cards/:card`

Get statistics for a specific card.

**Example:**
```bash
curl "http://localhost:8000/api/v1/stats/cards/AS"
```

### `GET /api/v1/stats/suits`

Get suit distribution statistics.

**Example:**
```bash
curl "http://localhost:8000/api/v1/stats/suits"
```

**Response:**
```json
[
  {
    "suit": "♠",
    "total_appearances": 1358,
    "expected_frequency": 25.0,
    "actual_frequency": 24.98,
    "deviation": -0.02
  }
]
```

### `GET /api/v1/stats/ranks`

Get rank distribution statistics.

**Example:**
```bash
curl "http://localhost:8000/api/v1/stats/ranks"
```

**Response:**
```json
[
  {
    "rank": "A",
    "total_appearances": 417,
    "expected_frequency": 7.692,
    "actual_frequency": 7.676,
    "deviation": -0.016
  }
]
```

### `GET /api/v1/stats/chi-squared`

Get chi-squared randomness test results.

**Example:**
```bash
curl "http://localhost:8000/api/v1/stats/chi-squared"
```

**Response:**
```json
{
  "chi_squared": 52.45,
  "degrees_of_freedom": 51,
  "p_value": 0.15,
  "result": "PASS",
  "interpretation": "Distribution is consistent with random expectation (p > 0.05)"
}
```

---

## Analysis Endpoints

### `GET /api/v1/analysis/randomness`

Get comprehensive randomness analysis report.

**Example:**
```bash
curl "http://localhost:8000/api/v1/analysis/randomness"
```

**Response:**
```json
{
  "summary": {
    "total_hands": 1234,
    "total_completed_hands": 987,
    "total_revealed_cards": 5432,
    "unique_games": 42,
    "block_height_range": "1-12345"
  },
  "card_chi_squared": {
    "chi_squared": 52.45,
    "degrees_of_freedom": 51,
    "p_value": 0.15,
    "result": "PASS",
    "interpretation": "Distribution is consistent with random expectation"
  },
  "outlier_cards": [],
  "duplicate_seeds": 0
}
```

### `GET /api/v1/analysis/outliers`

Get cards with significant deviation from expected frequency.

**Query Parameters:**
- `threshold` (float, optional): Deviation threshold percentage (default: 1.0)

**Example:**
```bash
curl "http://localhost:8000/api/v1/analysis/outliers?threshold=1.5"
```

**Response:**
```json
{
  "threshold": 1.5,
  "outlier_count": 3,
  "outliers": [
    {
      "card": "2H",
      "rank": "2",
      "suit": "♥",
      "total_appearances": 95,
      "expected_frequency": 1.923,
      "actual_frequency": 1.748,
      "deviation": -0.175,
      "deviation_percent": -9.10
    }
  ]
}
```

### `GET /api/v1/analysis/seeds`

Get deck seed entropy analysis.

**Example:**
```bash
curl "http://localhost:8000/api/v1/analysis/seeds"
```

**Response:**
```json
{
  "total_seeds": 1234,
  "unique_seeds": 1234,
  "duplicate_count": 0,
  "entropy_score": 100.0
}
```

---

## Player Endpoints

### `GET /api/v1/players/:address/stats`

Get player statistics.

**Example:**
```bash
curl "http://localhost:8000/api/v1/players/poker1abc.../stats"
```

**Response:**
```json
{
  "player_address": "poker1abc...",
  "total_hands": 156,
  "total_actions": 478,
  "total_buy_ins": 50000,
  "total_cash_outs": 55000,
  "net_profit": 5000,
  "session_count": 12,
  "avg_session_length": 245.5
}
```

### `GET /api/v1/players/:address/sessions`

Get player game sessions with pagination.

**Query Parameters:**
- `limit` (int, optional): Results per page (default: 50)
- `offset` (int, optional): Results offset (default: 0)

**Example:**
```bash
curl "http://localhost:8000/api/v1/players/poker1abc.../sessions?limit=10"
```

**Response:**
```json
{
  "data": [
    {
      "player_address": "poker1abc...",
      "game_id": "game123",
      "join_block": 12000,
      "leave_block": 12500,
      "buy_in_amount": 5000,
      "cash_out_amount": 5500,
      "created_at": "2024-02-24T10:00:00Z"
    }
  ],
  "pagination": {
    "limit": 10,
    "offset": 0,
    "total": 12
  }
}
```

---

## Error Responses

All endpoints return errors in a consistent format:

```json
{
  "error": "Error type",
  "message": "Detailed error message",
  "code": 400
}
```

**HTTP Status Codes:**
- `200` - Success
- `400` - Bad Request (invalid parameters)
- `404` - Not Found
- `500` - Internal Server Error (database error)

---

## Example Usage

### Using cURL

```bash
# Get health status
curl http://localhost:8000/health

# Get first 10 hands
curl "http://localhost:8000/api/v1/hands?limit=10"

# Get stats summary
curl http://localhost:8000/api/v1/stats/summary

# Get randomness report
curl http://localhost:8000/api/v1/analysis/randomness

# Get player stats
curl http://localhost:8000/api/v1/players/poker1abc.../stats
```

### Using JavaScript (fetch)

```javascript
// Get hands
const response = await fetch('http://localhost:8000/api/v1/hands?limit=10');
const data = await response.json();
console.log(data);

// Get stats summary
const stats = await fetch('http://localhost:8000/api/v1/stats/summary');
const summary = await stats.json();
console.log(summary);
```

### Using Python (requests)

```python
import requests

# Get hands
response = requests.get('http://localhost:8000/api/v1/hands', params={'limit': 10})
data = response.json()
print(data)

# Get stats summary
summary = requests.get('http://localhost:8000/api/v1/stats/summary').json()
print(summary)
```

---

## Development

### Running Tests

```bash
# Run API in development mode
ENVIRONMENT=development ./api

# Run with verbose logging
GIN_MODE=debug ./api
```

### Building

```bash
# Build for current platform
go build -o api ./cmd/api

# Build for Linux
GOOS=linux GOARCH=amd64 go build -o api-linux ./cmd/api
```

---

## CORS Configuration

By default, the API allows requests from all origins (`*`). To restrict CORS:

```bash
CORS_ORIGINS=http://localhost:3000 ./api
```

For multiple origins, modify the `loadConfig()` function in `cmd/api/main.go`.
