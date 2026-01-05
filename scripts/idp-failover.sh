#!/bin/bash
# =============================================================================
# IDP Failover Script (Emergency Failover)
# =============================================================================
# Emergency failover when the primary node has FAILED. This script:
#
# 1. Verifies the primary is actually down (or --force to override)
# 2. Removes the failed node from Traefik load balancer
# 3. Promotes this standby to primary
# 4. Updates local Keycloak to use local database
# 5. Attempts to stop Keycloak on failed node (if reachable)
#
# Usage: sudo ./idp-failover.sh [--force] [--dry-run]
#
# Options:
#   --force    Proceed even if primary appears reachable
#   --dry-run  Show what would be done without making changes
#
# Run this from the STANDBY node (the one that should become primary)
# =============================================================================

set -euo pipefail

# Configuration
PG_CONTAINER="postgres-lxc"
KC_CONTAINER="keycloak-lxc"
PG_VERSION="16"
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
KC_CONF="/opt/keycloak/conf/keycloak.conf"

# Traefik nodes (to update load balancer)
TRAEFIK_NODES=("sec001" "sec002")
TRAEFIK_CONFIG="/srv/security-stack/systems/traefik/dynamic/keycloak.yml"

# Parse arguments
FORCE=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Determine which node we're on
THIS_HOST=$(hostname -s)
case "${THIS_HOST}" in
    idp001|idp01)
        THIS_FQDN="idp01.outliertechnology.co.uk"
        THIS_SHORT="idp01"
        PEER_HOST="idp002"
        PEER_FQDN="idp01.outliertechnology.co.uk"
        PEER_SHORT="idp01"
        # Wait, this is wrong - if we're on idp001, peer is idp002
        PEER_HOST="idp002"
        PEER_FQDN="idp02.outliertechnology.co.uk"
        PEER_SHORT="idp02"
        ;;
    idp002|idp02)
        THIS_FQDN="idp02.outliertechnology.co.uk"
        THIS_SHORT="idp02"
        PEER_HOST="idp001"
        PEER_FQDN="idp01.outliertechnology.co.uk"
        PEER_SHORT="idp01"
        ;;
    *)
        echo "[ERROR] Unknown host: ${THIS_HOST}. Must run on idp001 or idp002."
        exit 1
        ;;
esac

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }
step() { echo -e "\n[STEP] $*"; }

run() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        echo "[DRY-RUN] Would run: $*"
    else
        log "Running: $*"
        eval "$@"
    fi
}

echo "=============================================="
echo "    IDP Emergency Failover"
echo "=============================================="
echo "  This Host:   ${THIS_HOST} (${THIS_FQDN})"
echo "  Failed Node: ${PEER_HOST} (${PEER_FQDN})"
echo "  Force Mode:  ${FORCE}"
echo "  Dry Run:     ${DRY_RUN}"
echo "=============================================="

# =============================================================================
# Pre-flight Checks
# =============================================================================

step "1/7: Verifying this node is a standby..."

if ! lxc info ${PG_CONTAINER} >/dev/null 2>&1; then
    error "PostgreSQL container (${PG_CONTAINER}) not found!"
fi

IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${IS_STANDBY}" != "t" ]]; then
    error "This node is NOT a standby (pg_is_in_recovery = ${IS_STANDBY})"
    error "Failover must be run from the standby node."
fi
log "Confirmed: This node is currently a STANDBY"

step "2/7: Checking if primary (${PEER_HOST}) is actually down..."

PRIMARY_REACHABLE=0
if ssh -o ConnectTimeout=5 -o BatchMode=yes sysadmin@${PEER_HOST} "lxc exec ${PG_CONTAINER} -- pg_isready" >/dev/null 2>&1; then
    PRIMARY_REACHABLE=1
fi

if [[ ${PRIMARY_REACHABLE} -eq 1 ]]; then
    if [[ ${FORCE} -eq 0 ]]; then
        error "Primary (${PEER_HOST}) is STILL REACHABLE!"
        error "For planned role switch, use: sudo ./idp-role-switch.sh"
        error "If you're sure primary has failed, use: sudo ./idp-failover.sh --force"
    else
        warn "Primary appears reachable but --force was specified. Proceeding anyway."
    fi
else
    log "Confirmed: Primary (${PEER_HOST}) is UNREACHABLE"
fi

echo ""
warn "WARNING: This will:"
warn "  1. Remove ${PEER_SHORT} from Traefik load balancer"
warn "  2. Promote this node (${THIS_SHORT}) to PRIMARY"
warn "  3. Stop Keycloak on ${PEER_HOST} (if reachable)"
echo ""

if [[ ${DRY_RUN} -eq 0 ]]; then
    read -p "Proceed with emergency failover? (yes/no): " CONFIRM
    if [[ "${CONFIRM}" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# =============================================================================
# Remove failed node from Traefik
# =============================================================================

step "3/7: Removing ${PEER_SHORT} from Traefik load balancer..."

for TRAEFIK_NODE in "${TRAEFIK_NODES[@]}"; do
    log "Updating Traefik on ${TRAEFIK_NODE}..."
    if ssh -o ConnectTimeout=5 -o BatchMode=yes sysadmin@${TRAEFIK_NODE} "test -f ${TRAEFIK_CONFIG}" 2>/dev/null; then
        if [[ ${DRY_RUN} -eq 0 ]]; then
            # Remove the failed node's URL from keycloak.yml
            ssh sysadmin@${TRAEFIK_NODE} "
                sudo sed -i '/${PEER_FQDN}/d' ${TRAEFIK_CONFIG}
                echo 'Removed ${PEER_FQDN} from load balancer'
                grep -E 'url:' ${TRAEFIK_CONFIG} || true
            "
        else
            echo "[DRY-RUN] Would remove ${PEER_FQDN} from ${TRAEFIK_CONFIG} on ${TRAEFIK_NODE}"
        fi
    else
        warn "Cannot reach ${TRAEFIK_NODE} or config not found. Manual update may be needed."
    fi
done

# =============================================================================
# Promote PostgreSQL
# =============================================================================

step "4/7: Promoting PostgreSQL to primary..."

run "lxc exec ${PG_CONTAINER} -- sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl promote -D ${PG_DATA}"

if [[ ${DRY_RUN} -eq 0 ]]; then
    sleep 5
    if lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" | grep -q "f"; then
        log "PostgreSQL successfully promoted to PRIMARY!"
    else
        error "Promotion may have failed. Check PostgreSQL logs."
    fi
fi

# =============================================================================
# Update local Keycloak
# =============================================================================

step "5/7: Updating local Keycloak to use local database..."

LOCAL_PG_IP=$(lxc exec ${PG_CONTAINER} -- hostname -I | awk '{print $1}')
log "Local PostgreSQL IP: ${LOCAL_PG_IP}"

if [[ ${DRY_RUN} -eq 0 ]]; then
    lxc exec ${KC_CONTAINER} -- sed -i "s|db-url=jdbc:postgresql://[^/]*|db-url=jdbc:postgresql://${LOCAL_PG_IP}|" ${KC_CONF}
    log "Keycloak db-url updated"
    lxc exec ${KC_CONTAINER} -- grep "db-url" ${KC_CONF}
    lxc exec ${KC_CONTAINER} -- systemctl restart keycloak
    log "Keycloak restarted"
else
    echo "[DRY-RUN] Would update Keycloak to use ${LOCAL_PG_IP}"
fi

# =============================================================================
# Stop Keycloak on failed node (if reachable)
# =============================================================================

step "6/7: Attempting to stop Keycloak on failed node..."

if [[ ${PRIMARY_REACHABLE} -eq 1 ]]; then
    log "Failed node is reachable. Stopping Keycloak to prevent conflicts..."
    if [[ ${DRY_RUN} -eq 0 ]]; then
        ssh sysadmin@${PEER_HOST} "lxc exec ${KC_CONTAINER} -- systemctl stop keycloak" 2>/dev/null || true
        log "Keycloak stopped on ${PEER_HOST}"
    else
        echo "[DRY-RUN] Would stop Keycloak on ${PEER_HOST}"
    fi
else
    warn "Failed node (${PEER_HOST}) is not reachable. Keycloak may still be running."
    warn "When node recovers, run: sudo ./idp-reinstate.sh"
fi

# =============================================================================
# Summary
# =============================================================================

step "7/7: Failover complete!"

echo ""
echo "=============================================="
echo "    EMERGENCY FAILOVER COMPLETE"
echo "=============================================="
echo "  New PRIMARY:  ${THIS_HOST} (${THIS_FQDN})"
echo "  Failed Node:  ${PEER_HOST} (${PEER_FQDN})"
echo ""
echo "  Actions taken:"
echo "    ✓ Removed ${PEER_SHORT} from Traefik load balancer"
echo "    ✓ Promoted local PostgreSQL to PRIMARY"
echo "    ✓ Updated local Keycloak to use local database"
if [[ ${PRIMARY_REACHABLE} -eq 1 ]]; then
echo "    ✓ Stopped Keycloak on ${PEER_HOST}"
else
echo "    ✗ Could not stop Keycloak on ${PEER_HOST} (unreachable)"
fi
echo "=============================================="
echo ""
echo "NEXT STEPS:"
echo "1. Verify Keycloak is working:"
echo "   curl -sk https://idp.outliertechnology.co.uk/ -o /dev/null -w '%{http_code}\\n'"
echo ""
echo "2. When ${PEER_HOST} is fixed, reinstate it as standby:"
echo "   ssh sysadmin@${PEER_HOST}"
echo "   cd /srv/identity-stack/scripts"
echo "   sudo ./idp-reinstate.sh --primary ${THIS_SHORT}"
echo ""

