#!/bin/bash

###############################################################################
# Poker Indexer Deployment Script
#
# Deploys the indexer to a remote Linux server via SSH
#
# Usage:
#   ./deploy.sh <ssh_user@host> [node_rpc_url]
#
# Example:
#   ./deploy.sh ubuntu@192.168.1.100 http://localhost:26657
#   ./deploy.sh root@indexer.example.com https://rpc.pokerchain.io
#
# Environment Variables (optional):
#   SSH_KEY_PATH    - Path to SSH key (default: ~/.ssh/id_rsa)
#   DEPLOY_DIR      - Remote deployment directory (default: ~/poker-indexer)
#   DB_PASSWORD     - PostgreSQL password (default: poker_indexer_prod)
#   START_BLOCK     - Starting block for backfill (default: 1)
#   END_BLOCK       - Ending block for backfill (default: 0 = latest)
###############################################################################

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
if [ $# -lt 1 ]; then
    log_error "Usage: $0 <ssh_user@host> [node_rpc_url]"
    echo ""
    echo "Examples:"
    echo "  $0 ubuntu@192.168.1.100"
    echo "  $0 root@indexer.example.com http://localhost:26657"
    exit 1
fi

SSH_TARGET="$1"
NODE_RPC_URL="${2:-http://localhost:26657}"

# Configuration
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
DEPLOY_DIR="${DEPLOY_DIR:-poker-indexer}"
DB_PASSWORD="${DB_PASSWORD:-poker_indexer_prod}"
START_BLOCK="${START_BLOCK:-1}"
END_BLOCK="${END_BLOCK:-0}"

REPO_URL="git@github.com:block52/indexer.git"

log_info "==================================================================="
log_info "Poker Indexer Deployment"
log_info "==================================================================="
log_info "Target:       $SSH_TARGET"
log_info "Deploy Dir:   ~/$DEPLOY_DIR"
log_info "Node RPC:     $NODE_RPC_URL"
log_info "SSH Key:      $SSH_KEY_PATH"
log_info "Start Block:  $START_BLOCK"
log_info "End Block:    ${END_BLOCK} (0 = latest)"
log_info "==================================================================="
echo ""

# Verify SSH key exists
if [ ! -f "$SSH_KEY_PATH" ]; then
    log_error "SSH key not found at: $SSH_KEY_PATH"
    log_info "Set SSH_KEY_PATH environment variable to specify a different key"
    exit 1
fi

# Test SSH connection
log_info "Testing SSH connection..."
if ! ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET" "echo 'SSH connection successful'" > /dev/null 2>&1; then
    log_error "Cannot connect to $SSH_TARGET"
    log_info "Please verify:"
    log_info "  1. SSH key is correct: $SSH_KEY_PATH"
    log_info "  2. Host is reachable: ${SSH_TARGET#*@}"
    log_info "  3. SSH user has proper permissions"
    exit 1
fi
log_success "SSH connection verified"

# Deploy script that runs on remote server
REMOTE_DEPLOY_SCRIPT=$(cat << 'REMOTE_SCRIPT_EOF'
#!/bin/bash
set -e

DEPLOY_DIR="$1"
REPO_URL="$2"
NODE_RPC_URL="$3"
DB_PASSWORD="$4"
START_BLOCK="$5"
END_BLOCK="$6"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[REMOTE]${NC} $1"; }
log_success() { echo -e "${GREEN}[REMOTE]${NC} $1"; }
log_error() { echo -e "${RED}[REMOTE]${NC} $1"; }

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed on remote server"
    log_info "Installing Docker..."

    # Update package index
    sudo apt-get update

    # Install prerequisites
    sudo apt-get install -y ca-certificates curl gnupg lsb-release

    # Add Docker's official GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    # Set up repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Add current user to docker group
    sudo usermod -aG docker $USER

    log_success "Docker installed successfully"
fi

# Check if docker compose is available
if ! docker compose version &> /dev/null; then
    log_error "Docker Compose plugin not available"
    exit 1
fi

log_success "Docker is installed"

# Check if git is installed
if ! command -v git &> /dev/null; then
    log_info "Installing git..."
    sudo apt-get update
    sudo apt-get install -y git
    log_success "Git installed"
fi

# Create or update repository
if [ -d "$DEPLOY_DIR" ]; then
    log_info "Repository exists, pulling latest changes..."
    cd "$DEPLOY_DIR"
    git fetch origin
    git reset --hard origin/main || git reset --hard origin/master
    log_success "Repository updated"
else
    log_info "Cloning repository..."
    git clone "$REPO_URL" "$DEPLOY_DIR"
    cd "$DEPLOY_DIR"
    log_success "Repository cloned"
fi

# Create .env file for production
log_info "Creating production environment configuration..."
cat > .env << ENV_EOF
# PostgreSQL Configuration
POSTGRES_USER=poker
POSTGRES_PASSWORD=${DB_PASSWORD}
POSTGRES_DB=poker_hands
DB_HOST=postgres
DB_PORT=5432

# Indexer Configuration
NODE_RPC_URL=${NODE_RPC_URL}
START_BLOCK=${START_BLOCK}
END_BLOCK=${END_BLOCK}
ENV_EOF

log_success "Environment configuration created"

# Stop any running containers
log_info "Stopping existing containers..."
docker compose down || true

# Build and start PostgreSQL
log_info "Starting PostgreSQL database..."
docker compose up -d postgres

# Wait for PostgreSQL to be healthy
log_info "Waiting for PostgreSQL to be ready..."
RETRY_COUNT=0
MAX_RETRIES=30
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if docker compose exec -T postgres pg_isready -U poker -d poker_hands > /dev/null 2>&1; then
        log_success "PostgreSQL is ready"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo -n "."
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    log_error "PostgreSQL failed to start within expected time"
    docker compose logs postgres
    exit 1
fi

# Build the indexer binary (if not already built or outdated)
log_info "Building indexer binary..."
if ! command -v go &> /dev/null; then
    log_info "Go is not installed, installing..."

    # Download and install Go
    GO_VERSION="1.22.0"
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
    rm "go${GO_VERSION}.linux-amd64.tar.gz"

    # Add to PATH
    export PATH=$PATH:/usr/local/go/bin
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc

    log_success "Go installed"
fi

# Build indexer
go build -o indexer ./cmd/indexer
log_success "Indexer binary built"

# Run backfill
log_info "Starting backfill process..."
log_info "This may take a while depending on the number of blocks..."

./backfill.sh "$NODE_RPC_URL" "$START_BLOCK" "$END_BLOCK"

log_success "Backfill completed"

# Show summary
log_info "Generating summary report..."
./run-analysis.sh summary || log_warning "Could not generate summary (may need data)"

log_success "Deployment complete!"
log_info ""
log_info "Next steps:"
log_info "  - Connect to database: PGPASSWORD=${DB_PASSWORD} psql -h localhost -U poker -d poker_hands"
log_info "  - Run analysis: cd $DEPLOY_DIR && ./run-analysis.sh report"
log_info "  - View logs: cd $DEPLOY_DIR && docker compose logs -f postgres"
log_info "  - Start Adminer UI: cd $DEPLOY_DIR && docker compose --profile tools up -d adminer"

REMOTE_SCRIPT_EOF
)

# Execute deployment on remote server
log_info "Executing deployment on remote server..."
echo ""

ssh -i "$SSH_KEY_PATH" "$SSH_TARGET" "bash -s" -- "$DEPLOY_DIR" "$REPO_URL" "$NODE_RPC_URL" "$DB_PASSWORD" "$START_BLOCK" "$END_BLOCK" << EOF
$REMOTE_DEPLOY_SCRIPT
EOF

# Check deployment status
if [ $? -eq 0 ]; then
    echo ""
    log_success "==================================================================="
    log_success "Deployment completed successfully!"
    log_success "==================================================================="
    echo ""
    log_info "To connect to the remote server:"
    log_info "  ssh -i $SSH_KEY_PATH $SSH_TARGET"
    echo ""
    log_info "To run analysis on remote server:"
    log_info "  ssh -i $SSH_KEY_PATH $SSH_TARGET 'cd $DEPLOY_DIR && ./run-analysis.sh report'"
    echo ""
    log_info "To connect to PostgreSQL:"
    log_info "  ssh -i $SSH_KEY_PATH $SSH_TARGET 'cd $DEPLOY_DIR && PGPASSWORD=$DB_PASSWORD psql -h localhost -U poker -d poker_hands'"
    echo ""
else
    log_error "Deployment failed"
    exit 1
fi
