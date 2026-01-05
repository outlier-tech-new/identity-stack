#!/bin/bash
# =============================================================================
# PostgreSQL Failover Script - Promote Standby to Primary
# =============================================================================
# Run this script on the STANDBY node (idp002) when the primary has failed.
#
# Usage: sudo ./failover-to-standby.sh [--force]
#
# What this script does:
#   1. Verifies this node is currently a standby
#   2. Verifies the primary is unreachable (unless --force)
#   3. Promotes PostgreSQL to primary
#   4. Updates local Keycloak to use local database
#   5. Attempts to update remote Keycloak (if reachable)
#   6. Provides instructions for bringing old primary back as standby
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration - should match setup-streaming-replication.sh
PG_CONTAINER="postgres-lxc"
KC_CONTAINER="keycloak-lxc"
PG_VERSION="16"
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"

# Node configuration
THIS_HOST=$(hostname -s)
PRIMARY_HOST="idp01.outliertechnology.co.uk"
STANDBY_HOST="idp02.outliertechnology.co.uk"
OTHER_IDP="idp001"  # The other IDP node to update

FORCE=0

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

Promote PostgreSQL standby to primary (failover).

Options:
    --force         Skip primary reachability check
    --dry-run       Show what would be done without executing
    -h, --help      Show this help

This script should be run on the STANDBY node when the primary has failed.
EOF
    exit 1
}

# Parse arguments
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
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

run() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo -e "${YELLOW}[DRY RUN]${NC} $*"
    else
        eval "$@"
    fi
}

echo ""
echo "=============================================="
echo "    PostgreSQL Failover - Promote Standby"
echo "=============================================="
echo ""
echo "  This Host:     ${THIS_HOST}"
echo "  Old Primary:   ${PRIMARY_HOST}"
echo "  Force Mode:    ${FORCE}"
echo "  Dry Run:       ${DRY_RUN}"
echo ""
echo "=============================================="
echo ""

# =============================================================================
# Pre-flight Checks
# =============================================================================

step "1/6: Verifying this node is a standby..."

if ! lxc info ${PG_CONTAINER} >/dev/null 2>&1; then
    error "PostgreSQL container (${PG_CONTAINER}) not found!"
    exit 1
fi

IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${IS_STANDBY}" != "t" ]]; then
    error "This node is NOT a standby (pg_is_in_recovery = ${IS_STANDBY})"
    error "Failover can only be run on a standby node."
    exit 1
fi
log "Confirmed: This node is currently a STANDBY"

# =============================================================================
# Check Primary Status
# =============================================================================

step "2/6: Checking primary status..."

if lxc exec ${PG_CONTAINER} -- pg_isready -h ${PRIMARY_HOST} -p 5432 -t 5 >/dev/null 2>&1; then
    if [[ "${FORCE}" -eq 0 ]]; then
        error "Primary (${PRIMARY_HOST}) is STILL REACHABLE!"
        error "Failover should only be performed when the primary is down."
        error "If you're sure, use --force to override."
        exit 1
    else
        warn "Primary is reachable but --force was specified. Proceeding anyway."
    fi
else
    log "Confirmed: Primary (${PRIMARY_HOST}) is UNREACHABLE"
fi

# =============================================================================
# Get Confirmation
# =============================================================================

if [[ "${DRY_RUN}" -eq 0 ]]; then
    echo ""
    warn "WARNING: This will promote this standby to PRIMARY."
    warn "The old primary will need to be rebuilt as a standby."
    echo ""
    read -p "Are you sure you want to proceed? (yes/no): " CONFIRM
    
    if [[ "${CONFIRM}" != "yes" ]]; then
        log "Aborted."
        exit 0
    fi
fi

# =============================================================================
# Promote PostgreSQL
# =============================================================================

step "3/6: Promoting PostgreSQL to primary..."

run "lxc exec ${PG_CONTAINER} -- sudo -u postgres pg_ctl promote -D ${PG_DATA}"

# Wait for promotion
sleep 3

# Verify promotion
IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${IS_STANDBY}" == "f" ]]; then
    log "PostgreSQL successfully promoted to PRIMARY!"
else
    error "Promotion may have failed. pg_is_in_recovery = ${IS_STANDBY}"
    error "Check PostgreSQL logs: lxc exec ${PG_CONTAINER} -- journalctl -u postgresql -n 50"
    exit 1
fi

# =============================================================================
# Update Local Keycloak
# =============================================================================

step "4/6: Updating local Keycloak to use local database..."

if lxc info ${KC_CONTAINER} >/dev/null 2>&1; then
    # Get this host's hostname for the new connection
    NEW_DB_HOST=$(hostname -f 2>/dev/null || echo "localhost")
    
    # For local connection, we can use the container IP directly
    CONTAINER_IP=$(lxc exec ${PG_CONTAINER} -- hostname -I | awk '{print $1}')
    
    log "Updating Keycloak to use local PostgreSQL (${CONTAINER_IP})..."
    run "lxc exec ${KC_CONTAINER} -- sed -i 's|db-url=jdbc:postgresql://[^/]*|db-url=jdbc:postgresql://${CONTAINER_IP}|' /opt/keycloak/conf/keycloak.conf"
    
    # Verify
    NEW_URL=$(lxc exec ${KC_CONTAINER} -- grep "db-url" /opt/keycloak/conf/keycloak.conf)
    log "New Keycloak db-url: ${NEW_URL}"
    
    # Restart Keycloak
    log "Restarting Keycloak..."
    run "lxc exec ${KC_CONTAINER} -- systemctl restart keycloak"
    sleep 5
    
    if lxc exec ${KC_CONTAINER} -- systemctl is-active keycloak >/dev/null 2>&1; then
        log "Local Keycloak restarted successfully"
    else
        warn "Keycloak may not have started properly. Check logs."
    fi
else
    warn "Keycloak container not found on this node."
fi

# =============================================================================
# Update Remote Keycloak (if reachable)
# =============================================================================

step "5/6: Attempting to update Keycloak on ${OTHER_IDP}..."

# Determine new primary's external hostname
if [[ "${THIS_HOST}" == "idp002" ]]; then
    NEW_PRIMARY_HOST="idp02.outliertechnology.co.uk"
else
    NEW_PRIMARY_HOST="idp01.outliertechnology.co.uk"
fi

if ssh -o ConnectTimeout=5 -o BatchMode=yes sysadmin@${OTHER_IDP} "echo ok" >/dev/null 2>&1; then
    log "Remote node ${OTHER_IDP} is reachable via SSH"
    
    # Update remote Keycloak
    run "ssh sysadmin@${OTHER_IDP} \"lxc exec keycloak-lxc -- sed -i 's|db-url=jdbc:postgresql://[^/]*|db-url=jdbc:postgresql://${NEW_PRIMARY_HOST}|' /opt/keycloak/conf/keycloak.conf\""
    run "ssh sysadmin@${OTHER_IDP} \"lxc exec keycloak-lxc -- systemctl restart keycloak\""
    
    log "Remote Keycloak on ${OTHER_IDP} updated"
else
    warn "Cannot reach ${OTHER_IDP} via SSH. Manual update may be needed when it's back online."
    echo ""
    echo "When ${OTHER_IDP} is available, run:"
    echo "  ssh sysadmin@${OTHER_IDP}"
    echo "  lxc exec keycloak-lxc -- sed -i 's|db-url=jdbc:postgresql://[^/]*|db-url=jdbc:postgresql://${NEW_PRIMARY_HOST}|' /opt/keycloak/conf/keycloak.conf"
    echo "  lxc exec keycloak-lxc -- systemctl restart keycloak"
fi

# =============================================================================
# Summary
# =============================================================================

step "6/6: Failover complete!"

echo ""
echo "=============================================="
echo "    FAILOVER COMPLETE"
echo "=============================================="
echo ""
echo "  New Primary:  ${THIS_HOST} (${NEW_PRIMARY_HOST})"
echo "  Old Primary:  ${PRIMARY_HOST} (needs rebuild as standby)"
echo ""
echo "  Keycloak Status:"
echo "    - Local: Updated to use local PostgreSQL"
if ssh -o ConnectTimeout=2 -o BatchMode=yes sysadmin@${OTHER_IDP} "echo ok" >/dev/null 2>&1; then
    echo "    - ${OTHER_IDP}: Updated to use ${NEW_PRIMARY_HOST}"
else
    echo "    - ${OTHER_IDP}: NEEDS MANUAL UPDATE when available"
fi
echo ""
echo "=============================================="
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Verify services are working:"
echo "   curl -sk https://idp.outliertechnology.co.uk/ -o /dev/null -w '%{http_code}\\n'"
echo ""
echo "2. When the old primary (${PRIMARY_HOST}) is back online,"
echo "   rebuild it as a standby:"
echo "   ssh sysadmin@idp001"
echo "   cd /srv/identity-stack/scripts"
echo "   sudo ./rebuild-as-standby.sh"
echo ""

