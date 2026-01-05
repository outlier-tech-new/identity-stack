#!/bin/bash
# =============================================================================
# Update Traefik Load Balancer (Granular)
# =============================================================================
# Adds or removes an IDP node from the Traefik load balancer.
#
# Usage: sudo ./idp-traefik-update.sh <add|remove> [--node <idp01|idp02>]
#
# Examples:
#   sudo ./idp-traefik-update.sh add              # Add this node
#   sudo ./idp-traefik-update.sh remove           # Remove this node
#   sudo ./idp-traefik-update.sh add --node idp01 # Add specific node
# =============================================================================

set -euo pipefail

TRAEFIK_NODES=("sec001" "sec002")
TRAEFIK_CONFIG="/srv/security-stack/systems/traefik/dynamic/keycloak.yml"

ACTION=""
TARGET_NODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        add|remove) ACTION="$1"; shift ;;
        --node) TARGET_NODE="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "${ACTION}" ]]; then
    echo "Usage: sudo ./idp-traefik-update.sh <add|remove> [--node <idp01|idp02>]"
    exit 1
fi

# Determine target
if [[ -z "${TARGET_NODE}" ]]; then
    THIS_HOST=$(hostname -s)
    case "${THIS_HOST}" in
        idp001|idp01) TARGET_NODE="idp01" ;;
        idp002|idp02) TARGET_NODE="idp02" ;;
        *) echo "Cannot determine node. Use --node."; exit 1 ;;
    esac
fi

TARGET_FQDN="${TARGET_NODE}.outliertechnology.co.uk"
TARGET_URL="http://${TARGET_FQDN}:8080"

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }

echo "=============================================="
echo "    Update Traefik Load Balancer"
echo "=============================================="
echo "  Action: ${ACTION}"
echo "  Node:   ${TARGET_NODE} (${TARGET_FQDN})"
echo "=============================================="

for TRAEFIK_NODE in "${TRAEFIK_NODES[@]}"; do
    log "Updating ${TRAEFIK_NODE}..."
    
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes sysadmin@${TRAEFIK_NODE} "test -f ${TRAEFIK_CONFIG}" 2>/dev/null; then
        warn "Cannot reach ${TRAEFIK_NODE} or config not found"
        continue
    fi
    
    if [[ "${ACTION}" == "remove" ]]; then
        # Remove the node
        if ssh sysadmin@${TRAEFIK_NODE} "grep -q '${TARGET_FQDN}' ${TRAEFIK_CONFIG}" 2>/dev/null; then
            ssh sysadmin@${TRAEFIK_NODE} "sudo sed -i '/${TARGET_FQDN}/d' ${TRAEFIK_CONFIG}"
            log "Removed ${TARGET_FQDN} from ${TRAEFIK_NODE}"
        else
            log "${TARGET_FQDN} not in config on ${TRAEFIK_NODE}"
        fi
    else
        # Add the node
        if ssh sysadmin@${TRAEFIK_NODE} "grep -q '${TARGET_FQDN}' ${TRAEFIK_CONFIG}" 2>/dev/null; then
            log "${TARGET_FQDN} already in config on ${TRAEFIK_NODE}"
        else
            # Add after existing url lines
            ssh sysadmin@${TRAEFIK_NODE} "
                sudo sed -i '/url:.*outliertechnology.co.uk:8080/a\\          - url: \"${TARGET_URL}\"' ${TRAEFIK_CONFIG}
            "
            log "Added ${TARGET_FQDN} to ${TRAEFIK_NODE}"
        fi
    fi
    
    # Show current state
    log "Current backends on ${TRAEFIK_NODE}:"
    ssh sysadmin@${TRAEFIK_NODE} "grep 'url:' ${TRAEFIK_CONFIG} | sed 's/.*url: \"//;s/\"//'" 2>/dev/null || true
done

log "Done. Traefik will auto-reload config."

