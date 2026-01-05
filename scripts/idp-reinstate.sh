#!/bin/bash
# =============================================================================
# IDP Reinstate as Standby (Operational)
# =============================================================================
# Brings a previously failed node back as a STANDBY.
#
# This script orchestrates:
# 1. Stops local stack (via lib/idp-stop-stack.sh)
# 2. Rebuilds PostgreSQL as standby (via lib/idp-rebuild-standby.sh)
# 3. Switches Keycloak to primary's database (via lib/idp-switch-db.sh)
# 4. Starts local stack (via lib/idp-start-stack.sh)
# 5. Adds this node back to Traefik (via lib/idp-traefik-update.sh)
#
# Usage: sudo ./idp-reinstate.sh --primary <idp01|idp02>
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

PRIMARY_SHORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --primary) PRIMARY_SHORT="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "${PRIMARY_SHORT}" ]]; then
    echo "Usage: sudo ./idp-reinstate.sh --primary <idp01|idp02>"
    exit 1
fi

# Expand primary name
case "${PRIMARY_SHORT}" in
    idp01) PRIMARY_FQDN="idp01.outliertechnology.co.uk"; PRIMARY_HOST="idp001" ;;
    idp02) PRIMARY_FQDN="idp02.outliertechnology.co.uk"; PRIMARY_HOST="idp002" ;;
    *) error "Primary must be 'idp01' or 'idp02'" ;;
esac

# Determine this node
THIS_HOST=$(hostname -s)
case "${THIS_HOST}" in
    idp001|idp01) THIS_SHORT="idp01"; THIS_FQDN="idp01.outliertechnology.co.uk" ;;
    idp002|idp02) THIS_SHORT="idp02"; THIS_FQDN="idp02.outliertechnology.co.uk" ;;
    *) error "Unknown host: ${THIS_HOST}" ;;
esac

if [[ "${THIS_SHORT}" == "${PRIMARY_SHORT}" ]]; then
    error "Cannot reinstate self as standby! This node is specified as primary."
fi

# Get replication password
if [[ -z "${REPL_PASSWORD:-}" ]]; then
    read -s -p "Enter PostgreSQL replication password: " REPL_PASSWORD
    echo ""
    export REPL_PASSWORD
fi

echo "=============================================="
echo "    IDP Reinstate as Standby"
echo "=============================================="
echo "  This Node: ${THIS_HOST} (will become STANDBY)"
echo "  Primary:   ${PRIMARY_HOST} (${PRIMARY_FQDN})"
echo "=============================================="

# =============================================================================
# Reinstate Steps
# =============================================================================

step "1/5: Verifying primary is available..."
PG_CONTAINER="postgres-lxc"
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes sysadmin@${PRIMARY_HOST} "lxc exec ${PG_CONTAINER} -- pg_isready" >/dev/null 2>&1; then
    error "Cannot reach primary (${PRIMARY_HOST})"
fi

# Verify it's actually primary
PRIMARY_IS_STANDBY=$(ssh sysadmin@${PRIMARY_HOST} "lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc \"SELECT pg_is_in_recovery();\"" 2>/dev/null || echo "error")
if [[ "${PRIMARY_IS_STANDBY}" != "f" ]]; then
    error "${PRIMARY_HOST} is not running as PRIMARY!"
fi
log "Confirmed: ${PRIMARY_HOST} is PRIMARY"

step "2/5: Stopping local stack..."
bash "${LIB_DIR}/idp-stop-stack.sh" --force

step "3/5: Rebuilding PostgreSQL as standby..."
bash "${LIB_DIR}/idp-rebuild-standby.sh" --primary ${PRIMARY_FQDN}

step "4/5: Configuring and starting Keycloak..."
bash "${LIB_DIR}/idp-switch-db.sh" --db-host ${PRIMARY_FQDN} --no-restart
bash "${LIB_DIR}/idp-start-stack.sh"

step "5/5: Adding this node back to Traefik..."
bash "${LIB_DIR}/idp-traefik-update.sh" add --node ${THIS_SHORT}

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "    REINSTATEMENT COMPLETE"
echo "=============================================="
echo "  This Node: ${THIS_HOST} - STANDBY"
echo "  Primary:   ${PRIMARY_HOST} - PRIMARY"
echo "  Traefik:   Added back to load balancer"
echo ""
echo "VERIFY:"
echo "1. Check replication:"
echo "   ./lib/idp-status.sh"
echo ""
echo "2. Test Keycloak:"
echo "   curl -sk https://idp.outliertechnology.co.uk/ -o /dev/null -w '%{http_code}\\n'"
echo "=============================================="
