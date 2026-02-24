#!/bin/bash

###############################################################################
# Poker Indexer Production Deployment Script
#
# Interactive deployment with options for:
# - Docker deployment vs native deployment
# - UFW firewall configuration
# - Nginx reverse proxy setup
# - SSL certificate configuration
#
# Usage:
#   ./deploy-production.sh
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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
   log_error "Please run as root or with sudo"
   exit 1
fi

# Welcome banner
clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║     Poker Hand Distribution Indexer                      ║
║     Production Deployment                                ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF

echo ""
log_info "This script will help you deploy the poker indexer in production"
echo ""

# Configuration
read -p "Enter Pokerchain RPC URL (e.g., http://node1.block52.xyz:26657): " NODE_RPC
read -p "Enter Pokerchain API URL (e.g., https://node1.block52.xyz): " NODE_API
read -p "Enter deployment directory [/opt/poker-indexer]: " DEPLOY_DIR
DEPLOY_DIR=${DEPLOY_DIR:-/opt/poker-indexer}

read -p "Enter database password [generate random]: " DB_PASSWORD
if [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    log_info "Generated database password: $DB_PASSWORD"
fi

# Deployment method
echo ""
log_step "Deployment Method"
echo "1) Docker (recommended - easier maintenance)"
echo "2) Native (direct installation)"
read -p "Choose deployment method [1]: " DEPLOY_METHOD
DEPLOY_METHOD=${DEPLOY_METHOD:-1}

# Firewall configuration
echo ""
log_step "Firewall Configuration"
read -p "Configure UFW firewall? (y/n) [y]: " CONFIGURE_UFW
CONFIGURE_UFW=${CONFIGURE_UFW:-y}

# Nginx setup
echo ""
log_step "Reverse Proxy Configuration"
read -p "Setup nginx reverse proxy for API? (y/n) [y]: " SETUP_NGINX
SETUP_NGINX=${SETUP_NGINX:-y}

if [[ "$SETUP_NGINX" =~ ^[Yy]$ ]]; then
    read -p "Enter domain name for API (e.g., api.block52.xyz): " DOMAIN_NAME
    read -p "Setup SSL with Let's Encrypt? (y/n) [y]: " SETUP_SSL
    SETUP_SSL=${SETUP_SSL:-y}
fi

# Confirm configuration
echo ""
log_step "Configuration Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Node RPC:           $NODE_RPC"
echo "  Node API:           $NODE_API"
echo "  Deploy Directory:   $DEPLOY_DIR"
echo "  Deployment Method:  $([ "$DEPLOY_METHOD" = "1" ] && echo "Docker" || echo "Native")"
echo "  Configure UFW:      $CONFIGURE_UFW"
echo "  Setup Nginx:        $SETUP_NGINX"
if [[ "$SETUP_NGINX" =~ ^[Yy]$ ]]; then
    echo "  Domain Name:        $DOMAIN_NAME"
    echo "  Setup SSL:          $SETUP_SSL"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Continue with deployment? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_warning "Deployment cancelled"
    exit 0
fi

# Start deployment
log_step "Starting Deployment"

# Create deployment directory
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

# Install git if needed
if ! command -v git &> /dev/null; then
    log_info "Installing git..."
    apt-get update
    apt-get install -y git
fi

# Clone or update repository
if [ -d ".git" ]; then
    log_info "Updating repository..."
    git fetch origin
    git reset --hard origin/main
else
    log_info "Cloning repository..."
    git clone https://github.com/block52/indexer.git .
fi

# Configure UFW if requested
if [[ "$CONFIGURE_UFW" =~ ^[Yy]$ ]]; then
    log_step "Configuring Firewall (UFW)"

    if ! command -v ufw &> /dev/null; then
        log_info "Installing UFW..."
        apt-get install -y ufw
    fi

    log_info "Current UFW status:"
    ufw status

    echo ""
    log_warning "Required ports:"
    echo "  - 22/tcp   (SSH - REQUIRED)"
    echo "  - 5432/tcp (PostgreSQL - if exposing database)"
    echo "  - 8000/tcp (API - if not using nginx)"
    echo "  - 80/tcp   (HTTP - if using nginx)"
    echo "  - 443/tcp  (HTTPS - if using nginx with SSL)"
    echo ""

    # Allow SSH first to avoid lockout
    log_info "Allowing SSH (port 22)..."
    ufw allow 22/tcp

    if [[ "$SETUP_NGINX" =~ ^[Yy]$ ]]; then
        log_info "Allowing HTTP (port 80) and HTTPS (port 443)..."
        ufw allow 80/tcp
        ufw allow 443/tcp
    else
        read -p "Allow API port 8000 externally? (y/n) [n]: " ALLOW_API_PORT
        if [[ "$ALLOW_API_PORT" =~ ^[Yy]$ ]]; then
            ufw allow 8000/tcp
        fi
    fi

    read -p "Expose PostgreSQL port 5432 externally? (y/n) [n]: " ALLOW_DB_PORT
    if [[ "$ALLOW_DB_PORT" =~ ^[Yy]$ ]]; then
        log_warning "Warning: Exposing database port is a security risk!"
        ufw allow 5432/tcp
    fi

    # Enable UFW
    log_info "Enabling UFW..."
    echo "y" | ufw enable

    log_success "Firewall configured"
    ufw status verbose
fi

# Deploy based on method
if [ "$DEPLOY_METHOD" = "1" ]; then
    log_step "Docker Deployment"

    # Install Docker if needed
    if ! command -v docker &> /dev/null; then
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
    fi

    # Create docker-compose override for production
    log_info "Creating production docker-compose configuration..."
    cat > docker-compose.prod.yml << DOCKER_EOF
services:
  postgres:
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    restart: always

  indexer:
    build:
      context: .
      dockerfile: Dockerfile.indexer
    container_name: poker-indexer
    environment:
      - NODE_RPC=${NODE_RPC}
      - NODE_API=${NODE_API}
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_USER=poker
      - DB_PASSWORD=${DB_PASSWORD}
      - DB_NAME=poker_hands
    depends_on:
      postgres:
        condition: service_healthy
    restart: always
    networks:
      - indexer-network
    command: ["-node", "${NODE_RPC}", "-api", "${NODE_API}", "-start", "1", "-end", "0"]

  api:
    build:
      context: .
      dockerfile: Dockerfile.api
    container_name: poker-api
    environment:
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_USER=poker
      - DB_PASSWORD=${DB_PASSWORD}
      - DB_NAME=poker_hands
      - PORT=8000
    depends_on:
      postgres:
        condition: service_healthy
    restart: always
    networks:
      - indexer-network
    ports:
      - "8000:8000"
DOCKER_EOF

    # Create Dockerfile for indexer
    log_info "Creating Dockerfile for indexer..."
    cat > Dockerfile.indexer << 'INDEXER_EOF'
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o indexer ./cmd/indexer

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/indexer .
ENTRYPOINT ["./indexer"]
INDEXER_EOF

    # Create Dockerfile for API
    log_info "Creating Dockerfile for API..."
    cat > Dockerfile.api << 'API_EOF'
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o api ./cmd/api

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/api .
EXPOSE 8000
CMD ["./api"]
API_EOF

    # Start services
    log_info "Starting services with Docker Compose..."
    docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build

    log_success "Docker services started"

else
    log_step "Native Deployment"

    # Install Go if needed
    if ! command -v go &> /dev/null; then
        log_info "Installing Go..."
        wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
        rm go1.22.0.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
    fi

    # Install Docker for PostgreSQL
    if ! command -v docker &> /dev/null; then
        log_info "Installing Docker (for PostgreSQL)..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
    fi

    # Start PostgreSQL
    log_info "Starting PostgreSQL..."
    # Update password in docker-compose.yml
    sed -i "s/POSTGRES_PASSWORD: .*/POSTGRES_PASSWORD: ${DB_PASSWORD}/" docker-compose.yml
    docker compose up -d postgres

    # Wait for PostgreSQL
    log_info "Waiting for PostgreSQL to be ready..."
    sleep 10

    # Build binaries
    log_info "Building indexer binary..."
    /usr/local/go/bin/go build -o indexer ./cmd/indexer

    log_info "Building API binary..."
    /usr/local/go/bin/go build -o api ./cmd/api

    # Create systemd service for indexer
    log_info "Creating systemd service for indexer..."
    cat > /etc/systemd/system/poker-indexer.service << SERVICE_EOF
[Unit]
Description=Poker Hand Indexer
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${DEPLOY_DIR}
ExecStart=${DEPLOY_DIR}/indexer -node ${NODE_RPC} -api ${NODE_API} -db-host localhost -db-user poker -db-pass ${DB_PASSWORD} -db-name poker_hands -start 1 -end 0
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    # Create systemd service for API
    log_info "Creating systemd service for API..."
    cat > /etc/systemd/system/poker-api.service << API_SERVICE_EOF
[Unit]
Description=Poker Indexer REST API
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${DEPLOY_DIR}
Environment="DB_HOST=localhost"
Environment="DB_PORT=5432"
Environment="DB_USER=poker"
Environment="DB_PASSWORD=${DB_PASSWORD}"
Environment="DB_NAME=poker_hands"
Environment="PORT=8000"
ExecStart=${DEPLOY_DIR}/api
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
API_SERVICE_EOF

    # Reload and start services
    systemctl daemon-reload
    systemctl enable poker-indexer
    systemctl enable poker-api
    systemctl start poker-indexer
    systemctl start poker-api

    log_success "Services started"
fi

# Setup nginx if requested
if [[ "$SETUP_NGINX" =~ ^[Yy]$ ]]; then
    log_step "Configuring Nginx Reverse Proxy"

    # Install nginx
    if ! command -v nginx &> /dev/null; then
        log_info "Installing nginx..."
        apt-get update
        apt-get install -y nginx
    fi

    # Create nginx config
    log_info "Creating nginx configuration..."
    cat > /etc/nginx/sites-available/poker-api << NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    # API endpoints
    location / {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        # CORS headers
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range' always;
    }

    # Health check
    location /health {
        proxy_pass http://localhost:8000/health;
        access_log off;
    }
}
NGINX_EOF

    # Enable site
    ln -sf /etc/nginx/sites-available/poker-api /etc/nginx/sites-enabled/

    # Test nginx config
    nginx -t

    # Reload nginx
    systemctl reload nginx

    log_success "Nginx configured for ${DOMAIN_NAME}"

    # Setup SSL if requested
    if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
        log_step "Configuring SSL with Let's Encrypt"

        # Install certbot
        if ! command -v certbot &> /dev/null; then
            log_info "Installing certbot..."
            apt-get install -y certbot python3-certbot-nginx
        fi

        # Get certificate
        log_info "Obtaining SSL certificate..."
        certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email

        log_success "SSL certificate installed"
    fi
fi

# Create .env file
log_info "Creating .env file..."
cat > .env << ENV_EOF
# PostgreSQL Configuration
POSTGRES_USER=poker
POSTGRES_PASSWORD=${DB_PASSWORD}
POSTGRES_DB=poker_hands
DB_HOST=localhost
DB_PORT=5432

# Indexer Configuration
NODE_RPC_URL=${NODE_RPC}
NODE_API_URL=${NODE_API}
ENV_EOF

# Save configuration
cat > deployment-info.txt << INFO_EOF
Deployment Information
======================

Deployment Date: $(date)
Deployment Method: $([ "$DEPLOY_METHOD" = "1" ] && echo "Docker" || echo "Native")
Deploy Directory: ${DEPLOY_DIR}

Node Configuration:
  RPC URL: ${NODE_RPC}
  API URL: ${NODE_API}

Database:
  Host: localhost
  Port: 5432
  User: poker
  Password: ${DB_PASSWORD}
  Database: poker_hands

API:
  Port: 8000
  $(if [[ "$SETUP_NGINX" =~ ^[Yy]$ ]]; then echo "Domain: ${DOMAIN_NAME}"; fi)
  $(if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then echo "SSL: Enabled"; fi)

Service Status Commands:
$(if [ "$DEPLOY_METHOD" = "1" ]; then
    echo "  docker compose -f docker-compose.yml -f docker-compose.prod.yml ps"
    echo "  docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f"
else
    echo "  systemctl status poker-indexer"
    echo "  systemctl status poker-api"
    echo "  journalctl -u poker-indexer -f"
    echo "  journalctl -u poker-api -f"
fi)

Database Access:
  docker compose exec postgres psql -U poker -d poker_hands

API Endpoints:
  $(if [[ "$SETUP_NGINX" =~ ^[Yy]$ ]]; then
      if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
          echo "https://${DOMAIN_NAME}/health"
          echo "https://${DOMAIN_NAME}/api/v1/stats/summary"
      else
          echo "http://${DOMAIN_NAME}/health"
          echo "http://${DOMAIN_NAME}/api/v1/stats/summary"
      fi
  else
      echo "http://localhost:8000/health"
      echo "http://localhost:8000/api/v1/stats/summary"
  fi)

INFO_EOF

# Final summary
echo ""
echo ""
log_success "═══════════════════════════════════════════════════════════"
log_success "  Deployment Complete!"
log_success "═══════════════════════════════════════════════════════════"
echo ""
cat deployment-info.txt
echo ""
log_info "Deployment information saved to: ${DEPLOY_DIR}/deployment-info.txt"
echo ""

# Show next steps
log_step "Next Steps"
echo "1. Check service status:"
if [ "$DEPLOY_METHOD" = "1" ]; then
    echo "   docker compose -f docker-compose.yml -f docker-compose.prod.yml ps"
else
    echo "   systemctl status poker-indexer poker-api"
fi
echo ""
echo "2. Monitor logs:"
if [ "$DEPLOY_METHOD" = "1" ]; then
    echo "   docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f"
else
    echo "   journalctl -u poker-indexer -f"
fi
echo ""
echo "3. Test API:"
if [[ "$SETUP_NGINX" =~ ^[Yy]$ ]]; then
    if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
        echo "   curl https://${DOMAIN_NAME}/health"
    else
        echo "   curl http://${DOMAIN_NAME}/health"
    fi
else
    echo "   curl http://localhost:8000/health"
fi
echo ""
log_success "Done!"
