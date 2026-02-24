# Production Deployment Guide

This guide covers deploying the Poker Hand Indexer to production with Docker, firewall configuration, and optional nginx reverse proxy with SSL.

## Quick Start

```bash
# On your production server (as root or with sudo)
sudo ./deploy-production.sh
```

The script will interactively guide you through:
1. Node RPC/API configuration
2. Deployment method (Docker vs Native)
3. Firewall (UFW) setup
4. Nginx reverse proxy configuration
5. SSL certificate setup with Let's Encrypt

## Prerequisites

- Ubuntu/Debian Linux server
- Root or sudo access
- Domain name (if using nginx with SSL)

## Deployment Methods

### 1. Docker Deployment (Recommended)

**Pros:**
- Easier maintenance and updates
- Consistent environment
- Automatic restarts
- Easy rollbacks

**Services:**
- PostgreSQL (Docker container)
- Indexer (Docker container)
- API (Docker container)

**Management:**
```bash
# View status
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps

# View logs
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f

# Restart services
docker compose -f docker-compose.yml -f docker-compose.prod.yml restart

# Stop services
docker compose -f docker-compose.yml -f docker-compose.prod.yml down

# Update and redeploy
git pull origin main
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

### 2. Native Deployment

**Pros:**
- Lower resource usage
- Direct system integration
- Easier debugging

**Services:**
- PostgreSQL (Docker container)
- Indexer (systemd service)
- API (systemd service)

**Management:**
```bash
# View status
systemctl status poker-indexer
systemctl status poker-api

# View logs
journalctl -u poker-indexer -f
journalctl -u poker-api -f

# Restart services
systemctl restart poker-indexer
systemctl restart poker-api

# Stop services
systemctl stop poker-indexer
systemctl stop poker-api
```

## Firewall Configuration

The script configures UFW with the following ports:

### Required Ports
- **22/tcp** - SSH (always allowed to prevent lockout)

### Optional Ports
- **80/tcp** - HTTP (required if using nginx)
- **443/tcp** - HTTPS (required if using nginx with SSL)
- **8000/tcp** - API (only if NOT using nginx)
- **5432/tcp** - PostgreSQL (NOT recommended for security)

### Manual UFW Commands

```bash
# Check status
sudo ufw status verbose

# Allow a port
sudo ufw allow 80/tcp

# Deny a port
sudo ufw deny 5432/tcp

# Delete a rule
sudo ufw delete allow 5432/tcp

# Reload firewall
sudo ufw reload
```

## Nginx Reverse Proxy

If you chose to set up nginx, your API will be accessible via your domain name.

### Configuration Location
`/etc/nginx/sites-available/poker-api`

### Manual nginx Commands

```bash
# Test configuration
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx

# View logs
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log

# Edit configuration
sudo nano /etc/nginx/sites-available/poker-api
```

### Custom nginx Configuration

To customize nginx settings, edit `/etc/nginx/sites-available/poker-api`:

```nginx
server {
    listen 80;
    server_name your-domain.com;

    # Rate limiting (add to http block in /etc/nginx/nginx.conf)
    # limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;

    location / {
        # limit_req zone=api_limit burst=20 nodelay;
        proxy_pass http://localhost:8000;
        # ... rest of config
    }
}
```

## SSL Certificate

If you set up SSL, certificates are managed by Let's Encrypt via certbot.

### Certificate Management

```bash
# Renew certificates (runs automatically via cron)
sudo certbot renew

# Renew and reload nginx
sudo certbot renew --deploy-hook "systemctl reload nginx"

# List certificates
sudo certbot certificates

# Test renewal
sudo certbot renew --dry-run
```

### Auto-renewal

Certbot automatically sets up a cron job or systemd timer for renewal. Certificates renew automatically 30 days before expiration.

## Database Access

```bash
# Connect to database
docker compose exec postgres psql -U poker -d poker_hands

# Backup database
docker compose exec postgres pg_dump -U poker poker_hands > backup.sql

# Restore database
docker compose exec -T postgres psql -U poker -d poker_hands < backup.sql

# View database size
docker compose exec postgres psql -U poker -d poker_hands -c "SELECT pg_size_pretty(pg_database_size('poker_hands'));"
```

## Monitoring

### Check Indexer Progress

```bash
# Docker deployment
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs indexer | tail -20

# Native deployment
journalctl -u poker-indexer --since "10 minutes ago"
```

### Check API Health

```bash
# With nginx
curl https://your-domain.com/health

# Without nginx
curl http://localhost:8000/health
```

### Database Statistics

```bash
# Connect to database
docker compose exec postgres psql -U poker -d poker_hands

# Run queries
SELECT COUNT(*) FROM poker_hands;
SELECT COUNT(*) FROM revealed_cards;
SELECT * FROM total_hands_summary;
```

## Updating the Deployment

### Docker Method

```bash
cd /opt/poker-indexer
git pull origin main
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

### Native Method

```bash
cd /opt/poker-indexer
git pull origin main

# Rebuild binaries
/usr/local/go/bin/go build -o indexer ./cmd/indexer
/usr/local/go/bin/go build -o api ./cmd/api

# Restart services
systemctl restart poker-indexer
systemctl restart poker-api
```

## Troubleshooting

### Indexer Not Running

```bash
# Docker
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs indexer

# Native
systemctl status poker-indexer
journalctl -u poker-indexer -n 50
```

### API Not Accessible

```bash
# Check if API is running
curl http://localhost:8000/health

# Check nginx (if using)
sudo nginx -t
sudo systemctl status nginx

# Check firewall
sudo ufw status
```

### Database Connection Issues

```bash
# Check if PostgreSQL is running
docker compose ps postgres

# Test connection
docker compose exec postgres psql -U poker -d poker_hands -c "SELECT 1"

# Check logs
docker compose logs postgres
```

### Port Already in Use

```bash
# Find what's using a port
sudo lsof -i :8000
sudo ss -tlnp | grep 8000

# Kill process
sudo kill -9 <PID>
```

## Security Best Practices

1. **Never expose PostgreSQL port (5432) publicly**
2. **Use SSL for API in production**
3. **Keep database password secure**
4. **Regularly update system packages**
   ```bash
   sudo apt update && sudo apt upgrade
   ```
5. **Monitor logs for suspicious activity**
6. **Set up regular database backups**
7. **Use fail2ban for SSH protection**
   ```bash
   sudo apt install fail2ban
   sudo systemctl enable fail2ban
   ```

## Performance Tuning

### PostgreSQL

Edit docker-compose configuration to increase resources:

```yaml
postgres:
  command:
    - -c
    - max_connections=200
    - -c
    - shared_buffers=256MB
    - -c
    - effective_cache_size=1GB
```

### API

Set environment variables for the API:

```bash
# In docker-compose.prod.yml
environment:
  - GIN_MODE=release
  - PORT=8000
```

### Nginx

Add caching for static responses:

```nginx
# In /etc/nginx/sites-available/poker-api
location /api/v1/stats/ {
    proxy_cache_valid 200 5m;
    proxy_cache_bypass $http_pragma;
    # ... rest of config
}
```

## Backup Strategy

### Automated Backups

Create a cron job for daily backups:

```bash
# Create backup script
cat > /opt/poker-indexer/backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/backups/poker-indexer"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR
cd /opt/poker-indexer
docker compose exec -T postgres pg_dump -U poker poker_hands | gzip > $BACKUP_DIR/poker_hands_$DATE.sql.gz
# Keep only last 7 days
find $BACKUP_DIR -name "poker_hands_*.sql.gz" -mtime +7 -delete
EOF

chmod +x /opt/poker-indexer/backup.sh

# Add to crontab
crontab -e
# Add line:
# 0 2 * * * /opt/poker-indexer/backup.sh
```

## Support

For issues or questions:
- GitHub Issues: https://github.com/block52/indexer/issues
- Documentation: See README.md
