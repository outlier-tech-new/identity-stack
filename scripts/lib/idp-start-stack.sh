#!/bin/bash
# =============================================================================
# Start IDP Stack (Granular)
# =============================================================================
# Starts PostgreSQL and Keycloak on the local node.
#
# Usage: sudo ./idp-start-stack.sh
# =============================================================================

set -euo pipefail

KC_CONTAINER="keycloak-lxc"
PG_CONTAINER="postgres-lxc"

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }

THIS_HOST=$(hostname -s)

echo "=============================================="
echo "    Start IDP Stack on ${THIS_HOST}"
echo "=============================================="

# Start PostgreSQL first
log "Starting PostgreSQL..."
if lxc info ${PG_CONTAINER} >/dev/null 2>&1; then
    lxc exec ${PG_CONTAINER} -- systemctl start postgresql
    sleep 3
    if lxc exec ${PG_CONTAINER} -- pg_isready >/dev/null 2>&1; then
        log "PostgreSQL started and ready"
    else
        error "PostgreSQL failed to start"
    fi
else
    error "PostgreSQL container not found"
fi

# Start Keycloak
log "Starting Keycloak..."
if lxc info ${KC_CONTAINER} >/dev/null 2>&1; then
    lxc exec ${KC_CONTAINER} -- systemctl start keycloak
    log "Keycloak started"
else
    error "Keycloak container not found"
fi

echo ""
log "IDP stack started on ${THIS_HOST}"

