#!/bin/bash
# =============================================================================
# Rebuild PostgreSQL as Standby (Granular)
# =============================================================================
# Rebuilds the local PostgreSQL as a streaming standby from a primary.
# WARNING: This destroys all local PostgreSQL data!
#
# Usage: sudo ./idp-rebuild-standby.sh --replicate-from <hostname>
#
# Example: Rebuild this node to replicate from idp02:
#   sudo ./idp-rebuild-standby.sh --replicate-from idp02.outliertechnology.co.uk
#
# Environment:
#   REPL_PASSWORD - Replication user password (will prompt if not set)
# =============================================================================

set -euo pipefail

PG_CONTAINER="postgres-lxc"
PG_VERSION="16"
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"

PRIMARY_HOST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --replicate-from|--primary) PRIMARY_HOST="$2"; shift 2 ;;  # --primary kept for backwards compat
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "${PRIMARY_HOST}" ]]; then
    echo "Usage: sudo ./idp-rebuild-standby.sh --replicate-from <hostname>"
    echo ""
    echo "Rebuilds THIS node to replicate from the specified primary."
    echo ""
    echo "Example: sudo ./idp-rebuild-standby.sh --replicate-from idp02.outliertechnology.co.uk"
    exit 1
fi

if [[ -z "${REPL_PASSWORD:-}" ]]; then
    read -s -p "Enter replication password: " REPL_PASSWORD
    echo ""
fi

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }

THIS_HOST=$(hostname -s)

echo "=============================================="
echo "    Rebuild PostgreSQL as Standby"
echo "=============================================="
echo "  This Host: ${THIS_HOST}"
echo "  Primary:   ${PRIMARY_HOST}"
echo "=============================================="
echo ""
warn "WARNING: This will DESTROY all local PostgreSQL data!"
read -p "Continue? (yes/no): " CONFIRM
[[ "${CONFIRM}" != "yes" ]] && { echo "Aborted."; exit 0; }

# Verify primary is reachable
log "Testing connection to primary..."
if ! lxc exec ${PG_CONTAINER} -- pg_isready -h ${PRIMARY_HOST} -p 5432 -t 10 >/dev/null 2>&1; then
    error "Cannot reach primary at ${PRIMARY_HOST}:5432"
fi
log "Primary is reachable"

# Stop PostgreSQL
log "Stopping local PostgreSQL..."
lxc exec ${PG_CONTAINER} -- systemctl stop postgresql 2>/dev/null || true

# Clear data directory
log "Clearing local data directory..."
lxc exec ${PG_CONTAINER} -- bash -c "rm -rf ${PG_DATA}/*"

# Take base backup
log "Taking base backup from primary (this may take a while)..."
lxc exec ${PG_CONTAINER} -- sudo -u postgres bash -c "
    PGPASSWORD='${REPL_PASSWORD}' pg_basebackup \
        -h ${PRIMARY_HOST} \
        -U replicator \
        -D ${PG_DATA} \
        -Fp -Xs -P -R
"

if [[ $? -ne 0 ]]; then
    error "Base backup failed!"
fi
log "Base backup completed"

# Start PostgreSQL
log "Starting PostgreSQL in standby mode..."
lxc exec ${PG_CONTAINER} -- systemctl start postgresql
sleep 5

# Verify
IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${IS_STANDBY}" == "t" ]]; then
    log "SUCCESS: PostgreSQL running as STANDBY, replicating from ${PRIMARY_HOST}"
else
    error "PostgreSQL did not start in standby mode"
fi

