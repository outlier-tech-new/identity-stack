#!/bin/bash
# =============================================================================
# Deploy Identity Stack
# =============================================================================
# Master deployment script for the identity stack (Keycloak + Postgres).
# This script orchestrates the deployment in the correct order.
#
# Prerequisites:
# - Ubuntu 24.04 LTS
# - SSH access configured
# - LXD not yet installed (script will install it)
#
# Usage: sudo ./deploy-identity-stack.sh [--host <hostname>] [--dry-run]
#
# Environment Variables:
#   KEYCLOAK_ADMIN_PASSWORD - Keycloak admin password (prompted if not set)
#   POSTGRES_PASSWORD       - Postgres password (prompted if not set)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOST="${HOST:-$(hostname -s)}"
DRY_RUN=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy the identity stack (Keycloak + Postgres) on an LXD-enabled host.

Options:
    --host <hostname>   Set hostname (default: current hostname)
    --dry-run           Show what would be done without executing
    -h, --help          Show this help message

Steps performed:
    1. Set hostname and update /etc/hosts
    2. Install and configure LXD
    3. Set up LXD networking (lxdbr-idp bridge with 172.22.0.0/24)
    4. Deploy Postgres LXD container
    5. Deploy Keycloak LXD container
    6. Configure Keycloak with Postgres backend
    7. Set up port forwarding (8080, 9000 -> Keycloak container)

EOF
}

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $*"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*"
}

run() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo -e "${YELLOW}[DRY RUN]${NC} $*"
    else
        log "Running: $*"
        eval "$@"
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            HOST="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo ""
echo "=============================================="
echo "    Identity Stack Deployment"
echo "=============================================="
echo ""
echo "  Host:      ${HOST}"
echo "  Root Dir:  ${ROOT_DIR}"
echo "  Dry Run:   ${DRY_RUN}"
echo ""
echo "=============================================="
echo ""

# Check we're running as root
if [[ "${EUID}" -ne 0 ]] && [[ "${DRY_RUN}" -eq 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Prompt for passwords if not set
if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
    read -s -p "Enter Keycloak admin password: " KEYCLOAK_ADMIN_PASSWORD
    echo ""
    export KEYCLOAK_ADMIN_PASSWORD
fi

if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    read -s -p "Enter Postgres keycloak user password: " POSTGRES_PASSWORD
    echo ""
    export POSTGRES_PASSWORD
fi

# -----------------------------------------------------------------------------
# Step 1: Set Hostname
# -----------------------------------------------------------------------------
log "Step 1/7: Setting hostname..."
CURRENT_HOSTNAME=$(hostname)
if [[ "${CURRENT_HOSTNAME}" != "${HOST}" ]]; then
    run "hostnamectl set-hostname ${HOST}"
    if ! grep -q "^127.0.1.1.*${HOST}" /etc/hosts 2>/dev/null; then
        run "sed -i 's/^127.0.1.1.*/127.0.1.1\t${HOST}/' /etc/hosts || echo '127.0.1.1\t${HOST}' >> /etc/hosts"
    fi
    log_success "Hostname set to ${HOST}"
else
    log_success "Hostname already ${HOST}"
fi

# -----------------------------------------------------------------------------
# Step 2: Install LXD
# -----------------------------------------------------------------------------
log "Step 2/7: Installing LXD..."
if command -v lxd &> /dev/null; then
    log_success "LXD already installed"
else
    run "apt-get update -qq"
    run "apt-get install -y lxd lxd-client"
    log_success "LXD installed"
fi

# -----------------------------------------------------------------------------
# Step 3: Initialize LXD
# -----------------------------------------------------------------------------
log "Step 3/7: Initializing LXD..."
cd "${ROOT_DIR}/systems/lxd"

if lxc storage show default >/dev/null 2>&1; then
    log_success "LXD already initialized"
else
    run "bash setup-lxd-init.sh"
    log_success "LXD initialized"
fi

# -----------------------------------------------------------------------------
# Step 4: Set up LXD Networking
# -----------------------------------------------------------------------------
log "Step 4/7: Setting up LXD networking..."
if lxc network show lxdbr-idp >/dev/null 2>&1; then
    log_success "LXD network lxdbr-idp already exists"
else
    run "bash setup-lxd-network.sh"
    log_success "LXD network configured"
fi

# Set up LXD profile if needed
if lxc profile show idp-profile >/dev/null 2>&1; then
    log_success "LXD profile idp-profile already exists"
else
    run "bash setup-lxd-profile.sh"
    log_success "LXD profile created"
fi

# -----------------------------------------------------------------------------
# Step 5: Deploy Postgres Container
# -----------------------------------------------------------------------------
log "Step 5/7: Deploying Postgres container..."
cd "${ROOT_DIR}/systems/postgres-lxd"

if lxc info postgres-lxc >/dev/null 2>&1; then
    log_success "Postgres container already exists"
else
    run "bash deploy-postgres-container.sh"
    log_success "Postgres container deployed"
fi

# Configure Postgres
run "bash configure-postgres.sh"
log_success "Postgres configured"

# -----------------------------------------------------------------------------
# Step 6: Deploy Keycloak Container
# -----------------------------------------------------------------------------
log "Step 6/7: Deploying Keycloak container..."
cd "${ROOT_DIR}/systems/keycloak-lxd"

if lxc info keycloak-lxc >/dev/null 2>&1; then
    log_success "Keycloak container already exists"
else
    run "bash deploy-keycloak-container.sh"
    log_success "Keycloak container deployed"
fi

# Complete installation if needed
if ! lxc exec keycloak-lxc -- test -d /opt/keycloak/bin 2>/dev/null; then
    run "bash complete-keycloak-install.sh"
fi

# Configure Keycloak
run "bash configure-keycloak.sh"
log_success "Keycloak configured"

# -----------------------------------------------------------------------------
# Step 7: Set up Port Forwarding
# -----------------------------------------------------------------------------
log "Step 7/7: Setting up port forwarding..."
cd "${ROOT_DIR}/scripts"
run "bash setup-port-forward.sh"
log_success "Port forwarding configured"

# -----------------------------------------------------------------------------
# Final Verification
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "    Deployment Complete"
echo "=============================================="
echo ""

# Show container status
echo "LXD Containers:"
lxc list

echo ""
echo "Port Forwarding:"
iptables -t nat -L PREROUTING -n -v 2>/dev/null | grep -E "(8080|9000)" | head -5 || echo "  (check iptables rules)"

echo ""
echo "=============================================="
echo "    Next Steps"
echo "=============================================="
echo ""
echo "1. Verify Keycloak is running:"
echo "   curl http://localhost:8080/health/ready"
echo ""
echo "2. Access Keycloak admin console (from browser):"
echo "   https://idp.outliertechnology.co.uk/admin/"
echo ""
echo "3. Verify Traefik routing (from sec001):"
echo "   curl -k https://idp.outliertechnology.co.uk/"
echo ""
echo "4. Update DNS if this is a new host (already done for idp001)"
echo ""

