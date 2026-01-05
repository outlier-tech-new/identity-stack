#!/bin/bash
# =============================================================================
# IDP Role Switch Script (Planned Switchover)
# =============================================================================
# Gracefully switches primary/standby roles when BOTH nodes are healthy.
# This is for planned maintenance or load redistribution, NOT emergency failover.
#
# Usage: sudo ./idp-role-switch.sh
#
# This script:
# 1. Verifies both nodes are healthy
# 2. Promotes the current standby to primary
# 3. Demotes the current primary to standby  
# 4. Updates Keycloak on both nodes
# 5. No Traefik changes (both nodes stay in load balancer)
# =============================================================================

set -euo pipefail

# Configuration
PG_CONTAINER="postgres-lxc"
KC_CONTAINER="keycloak-lxc"
PG_VERSION="16"
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
KC_CONF="/opt/keycloak/conf/keycloak.conf"

# Determine which node we're on and set peer
THIS_HOST=$(hostname -s)
case "${THIS_HOST}" in
    idp001|idp01)
        THIS_FQDN="idp01.outliertechnology.co.uk"
        PEER_HOST="idp002"
        PEER_FQDN="idp02.outliertechnology.co.uk"
        ;;
    idp002|idp02)
        THIS_FQDN="idp02.outliertechnology.co.uk"
        PEER_HOST="idp001"
        PEER_FQDN="idp01.outliertechnology.co.uk"
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
    log "Running: $*"
    eval "$@"
}

echo "=============================================="
echo "    IDP Role Switch (Planned Switchover)"
echo "=============================================="
echo "  This Host: ${THIS_HOST} (${THIS_FQDN})"
echo "  Peer Host: ${PEER_HOST} (${PEER_FQDN})"
echo "=============================================="

# =============================================================================
# Pre-flight Checks
# =============================================================================

step "1/7: Checking local PostgreSQL status..."
LOCAL_IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${LOCAL_IS_STANDBY}" == "error" ]]; then
    error "Cannot connect to local PostgreSQL!"
fi

if [[ "${LOCAL_IS_STANDBY}" == "t" ]]; then
    LOCAL_ROLE="STANDBY"
    CURRENT_PRIMARY="${PEER_FQDN}"
    CURRENT_STANDBY="${THIS_FQDN}"
else
    LOCAL_ROLE="PRIMARY"
    CURRENT_PRIMARY="${THIS_FQDN}"
    CURRENT_STANDBY="${PEER_FQDN}"
fi
log "Local PostgreSQL is: ${LOCAL_ROLE}"

step "2/7: Checking peer node availability..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes sysadmin@${PEER_HOST} "lxc exec ${PG_CONTAINER} -- pg_isready" >/dev/null 2>&1; then
    error "Peer node (${PEER_HOST}) is not reachable or PostgreSQL is down!"
    error "For emergency failover with a failed node, use: sudo ./idp-failover.sh"
fi
log "Peer node (${PEER_HOST}) is healthy"

step "3/7: Checking peer PostgreSQL role..."
PEER_IS_STANDBY=$(ssh sysadmin@${PEER_HOST} "lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc \"SELECT pg_is_in_recovery();\"" 2>/dev/null || echo "error")

if [[ "${PEER_IS_STANDBY}" == "error" ]]; then
    error "Cannot query peer PostgreSQL!"
fi

if [[ "${LOCAL_ROLE}" == "PRIMARY" && "${PEER_IS_STANDBY}" != "t" ]]; then
    error "Configuration error: Local is PRIMARY but peer is not STANDBY!"
fi
if [[ "${LOCAL_ROLE}" == "STANDBY" && "${PEER_IS_STANDBY}" != "f" ]]; then
    error "Configuration error: Local is STANDBY but peer is not PRIMARY!"
fi

echo ""
echo "Current Configuration:"
echo "  PRIMARY:  ${CURRENT_PRIMARY}"
echo "  STANDBY:  ${CURRENT_STANDBY}"
echo ""
echo "After switch:"
echo "  PRIMARY:  ${CURRENT_STANDBY}"
echo "  STANDBY:  ${CURRENT_PRIMARY}"
echo ""

read -p "Proceed with role switch? (yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# Perform Role Switch
# =============================================================================

if [[ "${LOCAL_ROLE}" == "STANDBY" ]]; then
    # This node is standby - we'll promote it
    NEW_PRIMARY="${THIS_FQDN}"
    NEW_STANDBY="${PEER_FQDN}"
    
    step "4/7: Promoting local PostgreSQL to PRIMARY..."
    run "lxc exec ${PG_CONTAINER} -- sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl promote -D ${PG_DATA}"
    sleep 5
    
    # Verify promotion
    if lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" | grep -q "f"; then
        log "Local PostgreSQL successfully promoted to PRIMARY"
    else
        error "Promotion failed!"
    fi
    
    step "5/7: Converting peer (${PEER_HOST}) to STANDBY..."
    # Stop peer PostgreSQL, take base backup from new primary, restart as standby
    ssh sysadmin@${PEER_HOST} "
        lxc exec ${PG_CONTAINER} -- systemctl stop postgresql
        lxc exec ${PG_CONTAINER} -- bash -c 'rm -rf ${PG_DATA}/*'
        lxc exec ${PG_CONTAINER} -- sudo -u postgres pg_basebackup -h ${NEW_PRIMARY} -U replicator -D ${PG_DATA} -Fp -Xs -P -R
        lxc exec ${PG_CONTAINER} -- systemctl start postgresql
    "
    log "Peer converted to standby"
    
else
    # This node is primary - we need to run switch from the standby
    error "Role switch must be initiated from the STANDBY node."
    error "SSH to ${PEER_HOST} and run: sudo ./idp-role-switch.sh"
fi

step "6/7: Updating Keycloak configurations..."

# Update local Keycloak to use local database
log "Updating local Keycloak to use local PostgreSQL..."
LOCAL_PG_IP=$(lxc exec ${PG_CONTAINER} -- hostname -I | awk '{print $1}')
lxc exec ${KC_CONTAINER} -- sed -i "s|db-url=jdbc:postgresql://[^/]*|db-url=jdbc:postgresql://${LOCAL_PG_IP}|" ${KC_CONF}
lxc exec ${KC_CONTAINER} -- systemctl restart keycloak

# Update peer Keycloak to use new primary (this node)
log "Updating peer Keycloak to use new primary..."
ssh sysadmin@${PEER_HOST} "
    lxc exec ${KC_CONTAINER} -- sed -i 's|db-url=jdbc:postgresql://[^/]*|db-url=jdbc:postgresql://${NEW_PRIMARY}|' ${KC_CONF}
    lxc exec ${KC_CONTAINER} -- systemctl restart keycloak
"

step "7/7: Verifying new configuration..."

# Check replication on new primary
log "Checking replication status on new primary..."
lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -c "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"

echo ""
echo "=============================================="
echo "    ROLE SWITCH COMPLETE"
echo "=============================================="
echo "  New PRIMARY: ${NEW_PRIMARY}"
echo "  New STANDBY: ${NEW_STANDBY}"
echo ""
echo "  Both nodes remain in Traefik load balancer."
echo "  Both Keycloaks point to the new primary database."
echo "=============================================="

