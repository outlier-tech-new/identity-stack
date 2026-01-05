#!/bin/bash
# =============================================================================
# Promote PostgreSQL to Primary (Granular)
# =============================================================================
# Promotes the local PostgreSQL from standby to primary.
# Only works if PostgreSQL is currently in standby mode.
#
# Usage: sudo ./idp-promote-db.sh
# =============================================================================

set -euo pipefail

PG_CONTAINER="postgres-lxc"
PG_VERSION="16"
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }

THIS_HOST=$(hostname -s)

echo "=============================================="
echo "    Promote PostgreSQL on ${THIS_HOST}"
echo "=============================================="

# Verify container exists
if ! lxc info ${PG_CONTAINER} >/dev/null 2>&1; then
    error "PostgreSQL container not found"
fi

# Check current status
IS_STANDBY=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${IS_STANDBY}" == "error" ]]; then
    error "Cannot connect to PostgreSQL"
fi

if [[ "${IS_STANDBY}" != "t" ]]; then
    error "PostgreSQL is not a standby (pg_is_in_recovery=${IS_STANDBY}). Cannot promote."
fi

log "Current status: STANDBY"
log "Promoting to PRIMARY..."

lxc exec ${PG_CONTAINER} -- sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl promote -D ${PG_DATA}

sleep 5

# Verify promotion
NEW_STATUS=$(lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")

if [[ "${NEW_STATUS}" == "f" ]]; then
    log "SUCCESS: PostgreSQL promoted to PRIMARY"
else
    error "Promotion may have failed. Check: lxc exec ${PG_CONTAINER} -- journalctl -u postgresql -n 50"
fi

