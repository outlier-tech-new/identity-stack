#!/bin/bash
# =============================================================================
# IDP Failover (Operational)
# =============================================================================
# Emergency failover when the primary node has FAILED.
#
# This script orchestrates:
# 1. Removes failed node from Traefik (via lib/idp-traefik-update.sh)
# 2. Stops stack on failed node if reachable (via lib/idp-stop-stack.sh)
# 3. Promotes local PostgreSQL (via lib/idp-promote-db.sh)
# 4. Switches local Keycloak to local database (via lib/idp-switch-db.sh)
#
# Usage: sudo ./idp-failover.sh [--force] [--dry-run]
#
# Run this from the STANDBY node that should become the new primary.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Source helpers or define inline
log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }
step() { echo -e "\n[STEP] $*"; }

FORCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

PG_CONTAINER="postgres-lxc"
KC_CONTAINER="keycloak-lxc"

# Determine hosts
THIS_HOST=$(hostname -s)
case "${THIS_HOST}" in
    idp001|idp01)
        THIS_SHORT="idp01"
        THIS_FQDN="idp01.outliertechnology.co.uk"
        PEER_HOST="idp002"
        PEER_SHORT="idp02"
        PEER_FQDN="idp02.outliertechnology.co.uk"
        ;;
    idp002|idp02)
        THIS_SHORT="idp02"
        THIS_FQDN="idp02.outliertechnology.co.uk"
        PEER_HOST="idp001"
        PEER_SHORT="idp01"
        PEER_FQDN="idp01.outliertechnology.co.uk"
        ;;
    *)
        error "Unknown host: ${THIS_HOST}"
        ;;
esac

echo "=============================================="
echo "    IDP Emergency Failover"
echo "=============================================="
echo "  This Node:   ${THIS_HOST} (will become PRIMARY)"
echo "  Failed Node: ${PEER_HOST} (${PEER_FQDN})"
echo "  Force:       ${FORCE}"
echo "  Dry Run:     ${DRY_RUN}"
echo "=============================================="

# =============================================================================
# Pre-flight
# =============================================================================

step "1/5: Verifying this node is currently a standby..."

IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${IS_STANDBY}" != "t" ]]; then
    error "This node is NOT a standby. Cannot failover from here."
fi
log "Confirmed: This node is a STANDBY"

step "2/5: Checking if failed node is actually down..."

PEER_REACHABLE=0
if ssh -o ConnectTimeout=5 -o BatchMode=yes sysadmin@${PEER_HOST} "lxc exec ${PG_CONTAINER} -- pg_isready" >/dev/null 2>&1; then
    PEER_REACHABLE=1
fi

if [[ ${PEER_REACHABLE} -eq 1 && ${FORCE} -eq 0 ]]; then
    error "Peer (${PEER_HOST}) is still reachable!"
    error "Use --force if you're sure, or use idp-role-switch.sh for planned switchover."
fi

if [[ ${PEER_REACHABLE} -eq 1 ]]; then
    warn "Peer is reachable but --force specified. Continuing."
else
    log "Confirmed: Peer (${PEER_HOST}) is UNREACHABLE"
fi

if [[ ${DRY_RUN} -eq 0 ]]; then
    echo ""
    warn "This will promote ${THIS_HOST} to PRIMARY and remove ${PEER_SHORT} from Traefik."
    read -p "Proceed? (yes/no): " CONFIRM
    [[ "${CONFIRM}" != "yes" ]] && { echo "Aborted."; exit 0; }
fi

# =============================================================================
# Failover Steps
# =============================================================================

step "3/5: Removing failed node from Traefik..."
if [[ ${DRY_RUN} -eq 0 ]]; then
    bash "${LIB_DIR}/idp-traefik-update.sh" remove --node ${PEER_SHORT}
else
    echo "[DRY-RUN] Would run: idp-traefik-update.sh remove --node ${PEER_SHORT}"
fi

step "4/5: Stopping stack on failed node (if reachable)..."
if [[ ${PEER_REACHABLE} -eq 1 ]]; then
    if [[ ${DRY_RUN} -eq 0 ]]; then
        log "Stopping Keycloak on ${PEER_HOST}..."
        ssh sysadmin@${PEER_HOST} "lxc exec ${KC_CONTAINER} -- systemctl stop keycloak" 2>/dev/null || warn "Could not stop Keycloak"
        log "Stopping PostgreSQL on ${PEER_HOST}..."
        ssh sysadmin@${PEER_HOST} "lxc exec ${PG_CONTAINER} -- systemctl stop postgresql" 2>/dev/null || warn "Could not stop PostgreSQL"
    else
        echo "[DRY-RUN] Would stop stack on ${PEER_HOST}"
    fi
else
    log "Peer unreachable - skipping remote stop (will need manual cleanup when recovered)"
fi

step "5/5: Promoting local PostgreSQL and updating Keycloak..."
if [[ ${DRY_RUN} -eq 0 ]]; then
    # Promote database
    bash "${LIB_DIR}/idp-promote-db.sh"
    
    # Switch Keycloak to local database
    bash "${LIB_DIR}/idp-switch-db.sh" --db-host local
else
    echo "[DRY-RUN] Would run: idp-promote-db.sh"
    echo "[DRY-RUN] Would run: idp-switch-db.sh --db-host local"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "    FAILOVER COMPLETE"
echo "=============================================="
echo "  New PRIMARY: ${THIS_HOST} (${THIS_FQDN})"
echo "  Failed Node: ${PEER_HOST} - REMOVED from Traefik"
echo ""
echo "NEXT STEPS:"
echo "1. Verify Keycloak is working:"
echo "   curl -sk https://idp.outliertechnology.co.uk/ -o /dev/null -w '%{http_code}\\n'"
echo ""
echo "2. When ${PEER_HOST} is fixed, reinstate it as standby:"
echo "   ssh sysadmin@${PEER_HOST}"
echo "   cd /srv/identity-stack/scripts"
echo "   sudo ./idp-reinstate.sh --primary ${THIS_SHORT}"
echo "=============================================="
