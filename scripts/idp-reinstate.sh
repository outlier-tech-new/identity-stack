#!/bin/bash
# =============================================================================
# IDP Reinstate Script (Add node back as standby)
# =============================================================================
# Reinstates a previously failed node as a STANDBY after repairs.
#
# This script:
# 1. Verifies the primary is healthy
# 2. Rebuilds this node's PostgreSQL as a standby
# 3. Configures Keycloak to use the primary's database
# 4. Adds this node back to Traefik load balancer
#
# Usage: sudo ./idp-reinstate.sh --primary <primary_short_name>
#
# Example:
#   # If idp02 is now the primary and we're reinstating idp01:
#   ssh sysadmin@idp001
#   cd /srv/identity-stack/scripts
#   sudo ./idp-reinstate.sh --primary idp02
#
# Environment Variables:
#   REPL_PASSWORD - PostgreSQL replication password (will prompt if not set)
# =============================================================================

set -euo pipefail

# Configuration
PG_CONTAINER="postgres-lxc"
KC_CONTAINER="keycloak-lxc"
PG_VERSION="16"
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
KC_CONF="/opt/keycloak/conf/keycloak.conf"

# Traefik nodes
TRAEFIK_NODES=("sec001" "sec002")
TRAEFIK_CONFIG="/srv/security-stack/systems/traefik/dynamic/keycloak.yml"

# Parse arguments
PRIMARY_SHORT=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --primary)
            PRIMARY_SHORT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            echo "Usage: sudo ./idp-reinstate.sh --primary <idp01|idp02>"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ -z "${PRIMARY_SHORT}" ]]; then
    echo "Error: --primary is required"
    echo "Usage: sudo ./idp-reinstate.sh --primary <idp01|idp02>"
    exit 1
fi

# Validate and expand primary name
case "${PRIMARY_SHORT}" in
    idp01)
        PRIMARY_HOST="idp001"
        PRIMARY_FQDN="idp01.outliertechnology.co.uk"
        ;;
    idp02)
        PRIMARY_HOST="idp002"
        PRIMARY_FQDN="idp02.outliertechnology.co.uk"
        ;;
    *)
        echo "Error: Primary must be 'idp01' or 'idp02'"
        exit 1
        ;;
esac

# Determine this node
THIS_HOST=$(hostname -s)
case "${THIS_HOST}" in
    idp001|idp01)
        THIS_FQDN="idp01.outliertechnology.co.uk"
        THIS_SHORT="idp01"
        ;;
    idp002|idp02)
        THIS_FQDN="idp02.outliertechnology.co.uk"
        THIS_SHORT="idp02"
        ;;
    *)
        echo "[ERROR] Unknown host: ${THIS_HOST}. Must run on idp001 or idp002."
        exit 1
        ;;
esac

if [[ "${THIS_SHORT}" == "${PRIMARY_SHORT}" ]]; then
    echo "[ERROR] Cannot reinstate self as standby!"
    echo "This node (${THIS_SHORT}) is specified as the primary."
    exit 1
fi

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
echo "    IDP Reinstate as Standby"
echo "=============================================="
echo "  This Node:     ${THIS_HOST} (${THIS_FQDN})"
echo "  Will become:   STANDBY"
echo "  Primary Node:  ${PRIMARY_HOST} (${PRIMARY_FQDN})"
echo "  Dry Run:       ${DRY_RUN}"
echo "=============================================="

# Get replication password
if [[ -z "${REPL_PASSWORD:-}" ]]; then
    read -s -p "Enter PostgreSQL replication password: " REPL_PASSWORD
    echo ""
fi

# =============================================================================
# Pre-flight Checks
# =============================================================================

step "1/7: Verifying primary (${PRIMARY_HOST}) is available..."

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes sysadmin@${PRIMARY_HOST} "lxc exec ${PG_CONTAINER} -- pg_isready" >/dev/null 2>&1; then
    error "Cannot reach primary (${PRIMARY_HOST})!"
    error "Ensure the primary is running and accessible via SSH."
fi
log "Primary is reachable"

# Verify primary is actually a primary
PRIMARY_IS_STANDBY=$(ssh sysadmin@${PRIMARY_HOST} "lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc \"SELECT pg_is_in_recovery();\"" 2>/dev/null || echo "error")
if [[ "${PRIMARY_IS_STANDBY}" != "f" ]]; then
    error "The specified primary (${PRIMARY_HOST}) is not actually a PRIMARY!"
    error "pg_is_in_recovery() returned: ${PRIMARY_IS_STANDBY}"
fi
log "Confirmed: ${PRIMARY_HOST} is running as PRIMARY"

step "2/7: Checking local PostgreSQL status..."

LOCAL_STATUS="unknown"
if lxc exec ${PG_CONTAINER} -- pg_isready >/dev/null 2>&1; then
    LOCAL_IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
    if [[ "${LOCAL_IS_STANDBY}" == "t" ]]; then
        LOCAL_STATUS="standby"
        log "Local PostgreSQL is already a standby"
    elif [[ "${LOCAL_IS_STANDBY}" == "f" ]]; then
        LOCAL_STATUS="primary"
        warn "Local PostgreSQL is running as PRIMARY - will be rebuilt"
    fi
else
    LOCAL_STATUS="stopped"
    log "Local PostgreSQL is not running"
fi

echo ""
warn "This will REBUILD the local PostgreSQL data directory!"
warn "All local data will be replaced with a copy from ${PRIMARY_HOST}."
echo ""

if [[ ${DRY_RUN} -eq 0 ]]; then
    read -p "Proceed with reinstatement? (yes/no): " CONFIRM
    if [[ "${CONFIRM}" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# =============================================================================
# Stop local services
# =============================================================================

step "3/7: Stopping local Keycloak and PostgreSQL..."

if [[ ${DRY_RUN} -eq 0 ]]; then
    # Stop Keycloak first
    lxc exec ${KC_CONTAINER} -- systemctl stop keycloak 2>/dev/null || true
    log "Keycloak stopped"
    
    # Stop PostgreSQL
    lxc exec ${PG_CONTAINER} -- systemctl stop postgresql 2>/dev/null || true
    log "PostgreSQL stopped"
else
    echo "[DRY-RUN] Would stop Keycloak and PostgreSQL"
fi

# =============================================================================
# Rebuild PostgreSQL as standby
# =============================================================================

step "4/7: Rebuilding PostgreSQL as standby from ${PRIMARY_HOST}..."

if [[ ${DRY_RUN} -eq 0 ]]; then
    # Clear data directory
    lxc exec ${PG_CONTAINER} -- bash -c "rm -rf ${PG_DATA}/*"
    log "Cleared local data directory"
    
    # Take base backup from primary
    log "Taking base backup from primary (this may take a while)..."
    lxc exec ${PG_CONTAINER} -- sudo -u postgres bash -c "
        PGPASSWORD='${REPL_PASSWORD}' pg_basebackup \
            -h ${PRIMARY_FQDN} \
            -U replicator \
            -D ${PG_DATA} \
            -Fp -Xs -P -R
    "
    
    if [[ $? -ne 0 ]]; then
        error "Base backup failed!"
    fi
    log "Base backup completed"
    
    # Start PostgreSQL in standby mode
    lxc exec ${PG_CONTAINER} -- systemctl start postgresql
    sleep 5
    
    # Verify standby mode
    if lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" | grep -q "t"; then
        log "PostgreSQL is running in STANDBY mode"
    else
        error "PostgreSQL did not start in standby mode. Check logs."
    fi
else
    echo "[DRY-RUN] Would rebuild PostgreSQL as standby"
fi

# =============================================================================
# Configure Keycloak
# =============================================================================

step "5/7: Configuring Keycloak to use primary database..."

if [[ ${DRY_RUN} -eq 0 ]]; then
    lxc exec ${KC_CONTAINER} -- sed -i "s|db-url=jdbc:postgresql://[^/]*|db-url=jdbc:postgresql://${PRIMARY_FQDN}|" ${KC_CONF}
    log "Keycloak db-url updated to ${PRIMARY_FQDN}"
    lxc exec ${KC_CONTAINER} -- grep "db-url" ${KC_CONF}
    
    lxc exec ${KC_CONTAINER} -- systemctl start keycloak
    log "Keycloak started"
else
    echo "[DRY-RUN] Would configure Keycloak to use ${PRIMARY_FQDN}"
fi

# =============================================================================
# Add back to Traefik
# =============================================================================

step "6/7: Adding ${THIS_SHORT} back to Traefik load balancer..."

for TRAEFIK_NODE in "${TRAEFIK_NODES[@]}"; do
    log "Updating Traefik on ${TRAEFIK_NODE}..."
    if ssh -o ConnectTimeout=5 -o BatchMode=yes sysadmin@${TRAEFIK_NODE} "test -f ${TRAEFIK_CONFIG}" 2>/dev/null; then
        if [[ ${DRY_RUN} -eq 0 ]]; then
            # Check if already present
            if ssh sysadmin@${TRAEFIK_NODE} "grep -q '${THIS_FQDN}' ${TRAEFIK_CONFIG}" 2>/dev/null; then
                log "${THIS_FQDN} already in load balancer on ${TRAEFIK_NODE}"
            else
                # Add the URL after the existing servers line
                ssh sysadmin@${TRAEFIK_NODE} "
                    sudo sed -i '/url:.*outliertechnology.co.uk:8080/a\\          - url: \"http://${THIS_FQDN}:8080\"' ${TRAEFIK_CONFIG}
                    echo 'Added ${THIS_FQDN} to load balancer'
                    grep -E 'url:' ${TRAEFIK_CONFIG} || true
                "
            fi
        else
            echo "[DRY-RUN] Would add ${THIS_FQDN} to ${TRAEFIK_CONFIG} on ${TRAEFIK_NODE}"
        fi
    else
        warn "Cannot reach ${TRAEFIK_NODE} or config not found."
    fi
done

# =============================================================================
# Verify
# =============================================================================

step "7/7: Verifying reinstatement..."

if [[ ${DRY_RUN} -eq 0 ]]; then
    log "Checking replication status..."
    lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -c "SELECT pg_is_in_recovery() as is_standby, pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
    
    log "Checking Keycloak status..."
    sleep 5
    if lxc exec ${KC_CONTAINER} -- systemctl is-active keycloak >/dev/null 2>&1; then
        log "Keycloak is running"
    else
        warn "Keycloak may not be running. Check: lxc exec keycloak-lxc -- journalctl -u keycloak -n 50"
    fi
fi

echo ""
echo "=============================================="
echo "    REINSTATEMENT COMPLETE"
echo "=============================================="
echo "  This Node:    ${THIS_HOST} - STANDBY"
echo "  Primary Node: ${PRIMARY_HOST} - PRIMARY"
echo ""
echo "  Actions taken:"
echo "    ✓ Rebuilt PostgreSQL as standby"
echo "    ✓ Configured Keycloak to use ${PRIMARY_FQDN}"
echo "    ✓ Added ${THIS_SHORT} back to Traefik load balancer"
echo "=============================================="
echo ""
echo "VERIFY:"
echo "1. Test Keycloak login: https://idp.outliertechnology.co.uk/"
echo "2. Check replication on primary:"
echo "   ssh sysadmin@${PRIMARY_HOST}"
echo "   lxc exec postgres-lxc -- sudo -u postgres psql -c 'SELECT * FROM pg_stat_replication;'"
echo ""

