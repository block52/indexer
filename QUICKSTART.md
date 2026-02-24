# Quick Start Guide

Get the Poker Indexer running in 5 minutes.

## 🚀 Fast Setup

```bash
# 1. Start database
docker compose up -d postgres

# 2. Build indexer
go build -o indexer ./cmd/indexer

# 3. Index blocks from your node
./backfill.sh http://localhost:26657

# 4. Check results
./run-analysis.sh summary
```

## ✅ Verify Everything Works

```bash
# Database is running
docker compose ps
# Should show: poker-indexer-db   Up (healthy)

# Data is indexed
docker compose exec postgres psql -U poker -d poker_hands -c "SELECT COUNT(*) FROM poker_hands;"
# Should show: count > 0

# Analysis works
./run-analysis.sh summary
# Should show statistics
```

## 🌐 Add REST API (Optional)

```bash
# Build and start API
go build -o api ./cmd/api
./api

# Test it (in another terminal)
curl http://localhost:8000/health
curl http://localhost:8000/api/v1/stats/summary
```

## 📊 Common Commands

```bash
# Start database
docker compose up -d postgres

# Stop database
docker compose down

# View database logs
docker compose logs -f postgres

# Index all blocks
./backfill.sh http://localhost:26657

# Index specific range
./backfill.sh http://localhost:26657 1000 5000

# Quick stats
./run-analysis.sh summary

# Full randomness report
./run-analysis.sh report

# Database UI (optional)
docker compose --profile tools up -d adminer
open http://localhost:8080
```

## 🔧 Database Connection Info

- **Host**: localhost
- **Port**: 5432
- **User**: poker
- **Password**: poker_indexer_dev
- **Database**: poker_hands

## 📖 Full Documentation

- **README.md** - Complete documentation
- **API.md** - REST API reference
- **deploy.sh** - Remote server deployment

## 🆘 Troubleshooting

### Database won't start
```bash
# Check Docker is running
docker ps

# Restart database
docker compose restart postgres
```

### No data appearing
```bash
# Check node is accessible
curl http://localhost:26657/status

# Check database
docker compose exec postgres psql -U poker -d poker_hands -c "SELECT COUNT(*) FROM poker_hands;"
```

### Can't connect to API
```bash
# Check API is running
curl http://localhost:8000/health

# Check port isn't in use
lsof -i :8000
```

## 🎯 What's Next?

1. **Index more data**: Run backfill against production nodes
2. **Monitor continuously**: Set up cron job for regular indexing
3. **Build dashboards**: Use REST API to create visualizations
4. **Deploy to server**: Use `./deploy.sh` for remote deployment

For detailed documentation, see [README.md](README.md)
