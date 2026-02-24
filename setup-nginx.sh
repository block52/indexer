#!/bin/bash

###############################################################################
# Nginx & SSL Setup Script for Poker Indexer API
#
# This script:
# - Checks/installs nginx
# - Configures reverse proxy to API on port 8000
# - Sets up SSL with Let's Encrypt (optional)
#
# Usage:
#   sudo ./setup-nginx.sh
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
║     Poker Indexer API                                    ║
║     Nginx & SSL Setup                                    ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF

echo ""
log_info "This script will configure nginx as a reverse proxy for the API"
echo ""

# Get configuration
read -p "Enter domain name for API (e.g., api.block52.xyz): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    log_error "Domain name is required"
    exit 1
fi

read -p "Enter API port [8000]: " API_PORT
API_PORT=${API_PORT:-8000}

read -p "Setup SSL with Let's Encrypt? (y/n) [y]: " SETUP_SSL
SETUP_SSL=${SETUP_SSL:-y}

# Confirm configuration
echo ""
log_step "Configuration Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Domain:         $DOMAIN_NAME"
echo "  API Port:       $API_PORT"
echo "  Setup SSL:      $SETUP_SSL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Continue with this configuration? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_error "Setup cancelled"
    exit 1
fi

# Check and install nginx
log_step "Checking Nginx"

if command -v nginx &> /dev/null; then
    NGINX_VERSION=$(nginx -v 2>&1 | cut -d'/' -f2)
    log_info "Nginx is already installed (version: $NGINX_VERSION)"
else
    log_info "Nginx not found. Installing..."
    apt-get update -qq
    apt-get install -y nginx
    log_success "Nginx installed successfully"
fi

# Enable and start nginx
systemctl enable nginx
systemctl start nginx || systemctl restart nginx
log_success "Nginx is running"

# Create nginx configuration
log_step "Configuring Nginx"

NGINX_CONF="/etc/nginx/sites-available/poker-api"

cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;

    # Increase timeouts for long-running queries
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;

    # Enable compression
    gzip on;
    gzip_types application/json;
    gzip_min_length 1000;

    location / {
        proxy_pass http://localhost:$API_PORT;
        proxy_http_version 1.1;

        # Proxy headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # CORS headers (optional - uncomment if needed)
        # add_header 'Access-Control-Allow-Origin' '*' always;
        # add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        # add_header 'Access-Control-Allow-Headers' 'Content-Type' always;
    }

    # Health check endpoint
    location /health {
        proxy_pass http://localhost:$API_PORT/health;
        access_log off;
    }
}
EOF

log_success "Nginx configuration created: $NGINX_CONF"

# Enable the site
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/poker-api

# Remove default site if exists
if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
    log_info "Removed default nginx site"
fi

# Test nginx configuration
log_info "Testing nginx configuration..."
if nginx -t; then
    log_success "Nginx configuration is valid"
else
    log_error "Nginx configuration test failed"
    exit 1
fi

# Reload nginx
systemctl reload nginx
log_success "Nginx reloaded with new configuration"

# Setup SSL if requested
if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
    log_step "Setting up SSL Certificate"

    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        log_info "Installing certbot..."
        apt-get update -qq
        apt-get install -y certbot python3-certbot-nginx
        log_success "Certbot installed"
    else
        log_info "Certbot is already installed"
    fi

    # Important checks before SSL setup
    log_warning "Before continuing, ensure:"
    echo "  1. Domain $DOMAIN_NAME points to this server's IP"
    echo "  2. Port 80 is open in your firewall"
    echo "  3. No other service is using port 80"
    echo ""
    read -p "Ready to setup SSL? (y/n) [y]: " SSL_READY
    SSL_READY=${SSL_READY:-y}

    if [[ "$SSL_READY" =~ ^[Yy]$ ]]; then
        log_info "Obtaining SSL certificate from Let's Encrypt..."

        # Get email for Let's Encrypt
        read -p "Enter email address for SSL certificate notifications: " SSL_EMAIL

        if [ -z "$SSL_EMAIL" ]; then
            log_warning "No email provided, using --register-unsafely-without-email"
            certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email
        else
            certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "$SSL_EMAIL"
        fi

        if [ $? -eq 0 ]; then
            log_success "SSL certificate obtained and configured"
            log_info "Certificate will auto-renew via certbot systemd timer"

            # Verify auto-renewal is set up
            if systemctl is-enabled certbot.timer &> /dev/null; then
                log_success "Auto-renewal is enabled"
            else
                log_warning "Auto-renewal timer not found, enabling manually"
                systemctl enable certbot.timer
                systemctl start certbot.timer
            fi
        else
            log_error "Failed to obtain SSL certificate"
            log_info "You can try again later with: sudo certbot --nginx -d $DOMAIN_NAME"
        fi
    else
        log_info "Skipping SSL setup. You can run certbot later with:"
        echo "  sudo certbot --nginx -d $DOMAIN_NAME"
    fi
else
    log_info "Skipping SSL setup"
fi

# Final summary
log_step "Setup Complete!"
echo ""
log_success "Nginx is configured and running"
echo ""
echo "Your API is now accessible at:"
if [[ "$SETUP_SSL" =~ ^[Yy]$ ]] && [ "$SSL_READY" = "y" ]; then
    echo "  https://$DOMAIN_NAME"
    echo "  https://$DOMAIN_NAME/health"
    echo "  https://$DOMAIN_NAME/api/v1/stats/summary"
else
    echo "  http://$DOMAIN_NAME"
    echo "  http://$DOMAIN_NAME/health"
    echo "  http://$DOMAIN_NAME/api/v1/stats/summary"
fi
echo ""

# Test the setup
log_info "Testing API connectivity..."
sleep 2

if curl -sf http://localhost:$API_PORT/health > /dev/null; then
    log_success "API is responding on localhost:$API_PORT"
else
    log_warning "API is not responding on localhost:$API_PORT"
    log_info "Make sure the API service is running"
fi

# Useful commands
echo ""
log_step "Useful Commands"
echo ""
echo "View nginx configuration:"
echo "  sudo nano $NGINX_CONF"
echo ""
echo "Test nginx configuration:"
echo "  sudo nginx -t"
echo ""
echo "Reload nginx:"
echo "  sudo systemctl reload nginx"
echo ""
echo "View nginx logs:"
echo "  sudo tail -f /var/log/nginx/access.log"
echo "  sudo tail -f /var/log/nginx/error.log"
echo ""
echo "Renew SSL certificate manually:"
echo "  sudo certbot renew"
echo ""
echo "Test SSL certificate renewal:"
echo "  sudo certbot renew --dry-run"
echo ""
