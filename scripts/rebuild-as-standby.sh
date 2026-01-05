#!/bin/bash
# =============================================================================
# Rebuild Node as PostgreSQL Standby
# =============================================================================
# Run this script on a node that was previously the primary and needs to be
# rebuilt as a standby after failover.
#
# Usage: sudo ./rebuild-as-standby.sh [--primary <hostname>]
#
# What this script does:
#   1. Verifies this node is NOT currently a standby
#   2. Stops PostgreSQL
#   3. Takes a fresh base backup from the new primary
#   4. Configures as standby
#   5. Updates Keycloak to use the new primary
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
PG_CONTAINER="postgres-lxc"
KC_CONTAINER="keycloak-lxc"
PG_VERSION="16"
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
PG_CONF="/etc/postgresql/${PG_VERSION}/main"
REPL_USER="replicator"

# Default - can be overridden
NEW_PRIMARY_HOST="idp02.outliertechnology.co.uk"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step() { echo -e "${BLUE}[STEP]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Rebuild this node as a PostgreSQL standby.

Options:
    --primary <host>    Hostname of the new primary (default: idp02.outliertechnology.co.uk)
    -h, --help          Show this help

This script should be run on the OLD primary after failover has occurred.
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --primary)
            NEW_PRIMARY_HOST="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

echo ""
echo "=============================================="
echo "    Rebuild as PostgreSQL Standby"
echo "=============================================="
echo ""
echo "  This Host:    $(hostname -s)"
echo "  New Primary:  ${NEW_PRIMARY_HOST}"
echo ""
echo "=============================================="
echo ""

# =============================================================================
# Pre-flight Checks
# =============================================================================

step "1/7: Pre-flight checks..."

if ! lxc info ${PG_CONTAINER} >/dev/null 2>&1; then
    error "PostgreSQL container (${PG_CONTAINER}) not found!"
    exit 1
fi

# Check if already a standby
IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${IS_STANDBY}" == "t" ]]; then
    warn "This node is already a standby."
    read -p "Continue anyway? (yes/no): " CONFIRM
    if [[ "${CONFIRM}" != "yes" ]]; then
        exit 0
    fi
fi

# Check new primary is reachable
step "2/7: Testing connection to new primary (${NEW_PRIMARY_HOST})..."

if ! lxc exec ${PG_CONTAINER} -- pg_isready -h ${NEW_PRIMARY_HOST} -p 5432 -t 10; then
    error "Cannot connect to new primary at ${NEW_PRIMARY_HOST}:5432"
    error "Ensure the new primary is running and reachable."
    exit 1
fi
log "New primary is reachable"

# =============================================================================
# Get Replication Password
# =============================================================================

step "3/7: Getting replication credentials..."

if [[ -z "${REPL_PASSWORD:-}" ]]; then
    echo ""
    echo "Enter the replication password for user '${REPL_USER}':"
    echo "(This was shown when --primary was run on the new primary)"
    read -s -p "Password: " REPL_PASSWORD
    echo ""
fi

# Test the password
if ! lxc exec ${PG_CONTAINER} -- bash -c "PGPASSWORD='${REPL_PASSWORD}' psql -h ${NEW_PRIMARY_HOST} -U ${REPL_USER} -d postgres -c 'SELECT 1;'" >/dev/null 2>&1; then
    error "Password authentication failed for replication user."
    error "Check the password and try again."
    exit 1
fi
log "Replication credentials verified"

# =============================================================================
# Confirmation
# =============================================================================

echo ""
warn "WARNING: This will:"
warn "  1. Stop PostgreSQL on this node"
warn "  2. DELETE the existing database"
warn "  3. Take a fresh backup from ${NEW_PRIMARY_HOST}"
warn "  4. Configure as standby"
echo ""
read -p "Are you sure? (yes/no): " CONFIRM

if [[ "${CONFIRM}" != "yes" ]]; then
    log "Aborted."
    exit 0
fi

# =============================================================================
# Stop PostgreSQL and Remove Data
# =============================================================================

step "4/7: Stopping PostgreSQL and removing old data..."

lxc exec ${PG_CONTAINER} -- systemctl stop postgresql

# Backup and remove old data
lxc exec ${PG_CONTAINER} -- bash -c "
    if [[ -d ${PG_DATA} ]]; then
        mv ${PG_DATA} ${PG_DATA}.old.\$(date +%Y%m%d%H%M%S)
    fi
"
log "Old data directory backed up"

# =============================================================================
# Take Base Backup
# =============================================================================

step "5/7: Taking base backup from new primary..."

lxc exec ${PG_CONTAINER} -- sudo -u postgres bash -c "
    PGPASSWORD='${REPL_PASSWORD}' pg_basebackup \
        -h ${NEW_PRIMARY_HOST} \
        -U ${REPL_USER} \
        -D ${PG_DATA} \
        -Fp -Xs -P -R
"

if [[ $? -ne 0 ]]; then
    error "Base backup failed!"
    exit 1
fi
log "Base backup completed"

# =============================================================================
# Configure and Start Standby
# =============================================================================

step "6/7: Configuring and starting standby..."

# Ensure standby config exists
lxc exec ${PG_CONTAINER} -- bash -c "
    mkdir -p ${PG_CONF}/conf.d
    cat > ${PG_CONF}/conf.d/standby.conf << 'PGCONF'
# Standby Configuration
hot_standby = on
hot_standby_feedback = on
PGCONF
"

# Start PostgreSQL
lxc exec ${PG_CONTAINER} -- systemctl start postgresql
sleep 5

# Verify
IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${IS_STANDBY}" == "t" ]]; then
    log "PostgreSQL is running as STANDBY"
else
    error "PostgreSQL may not be in standby mode. Check logs."
fi

# =============================================================================
# Update Keycloak
# =============================================================================

step "7/7: Updating Keycloak to use new primary..."

if lxc info ${KC_CONTAINER} >/dev/null 2>&1; then
    lxc exec ${KC_CONTAINER} -- sed -i "s|db-url=jdbc:postgresql://[^/]*|db-url=jdbc:postgresql://${NEW_PRIMARY_HOST}|" /opt/keycloak/conf/keycloak.conf
    
    NEW_URL=$(lxc exec ${KC_CONTAINER} -- grep "db-url" /opt/keycloak/conf/keycloak.conf)
    log "Keycloak db-url: ${NEW_URL}"
    
    lxc exec ${KC_CONTAINER} -- systemctl restart keycloak
    sleep 5
    
    if lxc exec ${KC_CONTAINER} -- systemctl is-active keycloak >/dev/null 2>&1; then
        log "Keycloak restarted successfully"
    else
        warn "Keycloak may not have started. Check logs."
    fi
else
    warn "Keycloak container not found."
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "    REBUILD COMPLETE"
echo "=============================================="
echo ""
echo "  This node is now a STANDBY replicating from:"
echo "    ${NEW_PRIMARY_HOST}"
echo ""
echo "  Verify replication:"
echo "    ./setup-streaming-replication.sh --check"
echo ""
echo "  Check on new primary:"
echo "    ssh sysadmin@idp002"
echo "    cd /srv/identity-stack/systems/postgres-lxd"
echo "    ./setup-streaming-replication.sh --check"
echo ""

