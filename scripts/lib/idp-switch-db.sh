#!/bin/bash
# =============================================================================
# Switch Keycloak Database (Granular)
# =============================================================================
# Updates Keycloak to connect to a specific PostgreSQL host.
#
# Usage: sudo ./idp-switch-db.sh --db-host <hostname|ip>
#
# Examples:
#   sudo ./idp-switch-db.sh --db-host idp01.outliertechnology.co.uk
#   sudo ./idp-switch-db.sh --db-host 172.22.0.11  # Local container IP
#   sudo ./idp-switch-db.sh --db-host local        # Auto-detect local container
# =============================================================================

set -euo pipefail

KC_CONTAINER="keycloak-lxc"
PG_CONTAINER="postgres-lxc"
KC_CONF="/opt/keycloak/conf/keycloak.conf"

DB_HOST=""
NO_RESTART=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db-host) DB_HOST="$2"; shift 2 ;;
        --no-restart) NO_RESTART=1; shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "${DB_HOST}" ]]; then
    echo "Usage: sudo ./idp-switch-db.sh --db-host <hostname|ip|local>"
    exit 1
fi

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }

# Handle "local" keyword
if [[ "${DB_HOST}" == "local" ]]; then
    DB_HOST=$(lxc exec ${PG_CONTAINER} -- hostname -I | awk '{print $1}')
    log "Detected local PostgreSQL IP: ${DB_HOST}"
fi

echo "=============================================="
echo "    Switch Keycloak Database"
echo "=============================================="
echo "  New DB Host: ${DB_HOST}"
echo "=============================================="

# Update config
log "Updating Keycloak configuration..."
lxc exec ${KC_CONTAINER} -- sed -i "s|db-url=jdbc:postgresql://[^/]*|db-url=jdbc:postgresql://${DB_HOST}|" ${KC_CONF}

# Show new config
log "New configuration:"
lxc exec ${KC_CONTAINER} -- grep "db-url" ${KC_CONF}

# Restart unless told not to
if [[ ${NO_RESTART} -eq 0 ]]; then
    log "Restarting Keycloak..."
    lxc exec ${KC_CONTAINER} -- systemctl restart keycloak
    log "Keycloak restarted"
else
    log "Skipping restart (--no-restart specified)"
fi

log "Done"

