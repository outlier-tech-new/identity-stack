#!/bin/bash
# =============================================================================
# Stop IDP Stack (Granular)
# =============================================================================
# Stops Keycloak and PostgreSQL on the local node.
# Use this to cleanly take down a node before maintenance or after a failure.
#
# Usage: sudo ./idp-stop-stack.sh [--force]
#
# Options:
#   --force   Don't prompt for confirmation
# =============================================================================

set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

KC_CONTAINER="keycloak-lxc"
PG_CONTAINER="postgres-lxc"

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }

THIS_HOST=$(hostname -s)

echo "=============================================="
echo "    Stop IDP Stack on ${THIS_HOST}"
echo "=============================================="

if [[ ${FORCE} -eq 0 ]]; then
    read -p "Stop Keycloak and PostgreSQL on this node? (yes/no): " CONFIRM
    [[ "${CONFIRM}" != "yes" ]] && { echo "Aborted."; exit 0; }
fi

# Stop Keycloak first (graceful shutdown)
log "Stopping Keycloak..."
if lxc info ${KC_CONTAINER} >/dev/null 2>&1; then
    lxc exec ${KC_CONTAINER} -- systemctl stop keycloak 2>/dev/null || warn "Keycloak service not running"
    log "Keycloak stopped"
else
    warn "Keycloak container not found"
fi

# Stop PostgreSQL
log "Stopping PostgreSQL..."
if lxc info ${PG_CONTAINER} >/dev/null 2>&1; then
    lxc exec ${PG_CONTAINER} -- systemctl stop postgresql 2>/dev/null || warn "PostgreSQL service not running"
    log "PostgreSQL stopped"
else
    warn "PostgreSQL container not found"
fi

echo ""
log "IDP stack stopped on ${THIS_HOST}"

