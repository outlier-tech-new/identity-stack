#!/bin/bash
# =============================================================================
# IDP Role Switch (Operational)
# =============================================================================
# Planned switchover when BOTH nodes are healthy.
# This swaps primary and standby roles gracefully.
#
# This script orchestrates:
# 1. Verifies both nodes are healthy
# 2. Promotes local standby to primary
# 3. Rebuilds peer as new standby
# 4. Updates Keycloak on both nodes
# 5. No Traefik changes (both stay in load balancer)
#
# Usage: sudo ./idp-role-switch.sh
#
# Must be run from the STANDBY node (the one that will become primary).
#
# Environment:
#   REPL_PASSWORD - PostgreSQL replication password (will prompt if not set)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }
step() { echo -e "\n[STEP] $*"; }

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
echo "    IDP Planned Role Switch"
echo "=============================================="
echo "  This Node: ${THIS_HOST} (current standby -> new primary)"
echo "  Peer Node: ${PEER_HOST} (current primary -> new standby)"
echo "=============================================="

# =============================================================================
# Pre-flight Checks
# =============================================================================

step "1/6: Verifying local node is currently STANDBY..."
IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${IS_STANDBY}" != "t" ]]; then
    error "This node is NOT a standby. Role switch must be run from the standby."
    error "If this is the primary, SSH to ${PEER_HOST} and run the switch there."
fi
log "Confirmed: This node is STANDBY"

step "2/6: Verifying peer node is available and is PRIMARY..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes sysadmin@${PEER_HOST} "lxc exec ${PG_CONTAINER} -- pg_isready" >/dev/null 2>&1; then
    error "Peer (${PEER_HOST}) is not reachable. For emergency failover, use: sudo ./idp-failover.sh"
fi

PEER_IS_STANDBY=$(ssh sysadmin@${PEER_HOST} "lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc \"SELECT pg_is_in_recovery();\"" 2>/dev/null || echo "error")
if [[ "${PEER_IS_STANDBY}" != "f" ]]; then
    error "Peer (${PEER_HOST}) is not running as PRIMARY!"
fi
log "Confirmed: Peer (${PEER_HOST}) is PRIMARY"

# Get replication password
if [[ -z "${REPL_PASSWORD:-}" ]]; then
    read -s -p "Enter PostgreSQL replication password: " REPL_PASSWORD
    echo ""
    export REPL_PASSWORD
fi

echo ""
echo "After switch:"
echo "  NEW PRIMARY: ${THIS_HOST} (${THIS_FQDN})"
echo "  NEW STANDBY: ${PEER_HOST} (${PEER_FQDN})"
echo ""
read -p "Proceed with role switch? (yes/no): " CONFIRM
[[ "${CONFIRM}" != "yes" ]] && { echo "Aborted."; exit 0; }

# =============================================================================
# Role Switch Steps
# =============================================================================

step "3/6: Promoting local PostgreSQL to PRIMARY..."
bash "${LIB_DIR}/idp-promote-db.sh"

step "4/6: Updating local Keycloak to use local database..."
bash "${LIB_DIR}/idp-switch-db.sh" --db-host local

step "5/6: Converting peer to STANDBY..."
log "Stopping peer stack..."
ssh sysadmin@${PEER_HOST} "lxc exec ${KC_CONTAINER} -- systemctl stop keycloak" 2>/dev/null || true
ssh sysadmin@${PEER_HOST} "lxc exec ${PG_CONTAINER} -- systemctl stop postgresql" 2>/dev/null || true

log "Rebuilding peer as standby from this node..."
ssh sysadmin@${PEER_HOST} "
    export REPL_PASSWORD='${REPL_PASSWORD}'
    cd /srv/identity-stack/scripts/lib
    sudo -E ./idp-rebuild-standby.sh --primary ${THIS_FQDN}
"

step "6/6: Updating peer Keycloak and starting stack..."
ssh sysadmin@${PEER_HOST} "
    cd /srv/identity-stack/scripts/lib
    sudo ./idp-switch-db.sh --db-host ${THIS_FQDN} --no-restart
    sudo ./idp-start-stack.sh
"

# =============================================================================
# Verify
# =============================================================================

log "Verifying replication..."
sleep 3
lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -c "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"

echo ""
echo "=============================================="
echo "    ROLE SWITCH COMPLETE"
echo "=============================================="
echo "  New PRIMARY: ${THIS_HOST} (${THIS_FQDN})"
echo "  New STANDBY: ${PEER_HOST} (${PEER_FQDN})"
echo ""
echo "  Both nodes remain in Traefik load balancer."
echo "  Both Keycloaks point to the new primary."
echo "=============================================="
