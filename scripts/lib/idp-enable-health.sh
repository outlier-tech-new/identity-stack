#!/bin/bash
# =============================================================================
# Enable Keycloak Health Checks (Granular)
# =============================================================================
# Ensures Keycloak has health-enabled=true and port 9000 is forwarded.
# Run this on existing deployments to enable proper health endpoints.
#
# Usage: sudo ./idp-enable-health.sh
# =============================================================================

set -euo pipefail

KC_CONTAINER="keycloak-lxc"
KC_CONF="/opt/keycloak/conf/keycloak.conf"

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }

THIS_HOST=$(hostname -s)

echo "=============================================="
echo "    Enable Keycloak Health Checks"
echo "=============================================="
echo "  Host: ${THIS_HOST}"
echo "=============================================="

# Check container exists
if ! lxc info ${KC_CONTAINER} >/dev/null 2>&1; then
    error "Keycloak container not found"
fi

# =============================================================================
# Step 1: Enable health in keycloak.conf
# =============================================================================
log "Checking Keycloak configuration..."

HEALTH_ENABLED=$(lxc exec ${KC_CONTAINER} -- grep -c "^health-enabled=true" ${KC_CONF} 2>/dev/null || echo "0")

if [[ "${HEALTH_ENABLED}" == "0" ]]; then
    log "Adding health-enabled=true to keycloak.conf..."
    lxc exec ${KC_CONTAINER} -- bash -c "echo 'health-enabled=true' >> ${KC_CONF}"
    NEEDS_REBUILD=1
else
    log "health-enabled=true already configured"
    NEEDS_REBUILD=0
fi

METRICS_ENABLED=$(lxc exec ${KC_CONTAINER} -- grep -c "^metrics-enabled=true" ${KC_CONF} 2>/dev/null || echo "0")

if [[ "${METRICS_ENABLED}" == "0" ]]; then
    log "Adding metrics-enabled=true to keycloak.conf..."
    lxc exec ${KC_CONTAINER} -- bash -c "echo 'metrics-enabled=true' >> ${KC_CONF}"
    NEEDS_REBUILD=1
fi

# =============================================================================
# Step 2: Rebuild Keycloak if config changed
# =============================================================================
if [[ "${NEEDS_REBUILD}" == "1" ]]; then
    log "Rebuilding Keycloak with new configuration..."
    lxc exec ${KC_CONTAINER} -- sudo -u keycloak /opt/keycloak/bin/kc.sh build
    
    log "Restarting Keycloak..."
    lxc exec ${KC_CONTAINER} -- systemctl restart keycloak
    sleep 10
fi

# =============================================================================
# Step 3: Verify health endpoint
# =============================================================================
log "Verifying health endpoint on port 9000..."

if lxc exec ${KC_CONTAINER} -- curl -sf http://localhost:9000/health/ready >/dev/null 2>&1; then
    log "Health endpoint working: http://localhost:9000/health/ready"
    lxc exec ${KC_CONTAINER} -- curl -s http://localhost:9000/health/ready
    echo ""
else
    warn "Health endpoint not responding on port 9000"
    log "Checking if Keycloak is running..."
    lxc exec ${KC_CONTAINER} -- systemctl status keycloak --no-pager || true
fi

# =============================================================================
# Step 4: Ensure port 9000 is forwarded from host
# =============================================================================
log "Checking port 9000 forwarding..."

KEYCLOAK_IP=$(lxc exec ${KC_CONTAINER} -- hostname -I | awk '{print $1}')
PHYSICAL_IF=$(ip route | grep default | awk '{print $5}' | head -1)

if ! sudo iptables -t nat -C PREROUTING -i "${PHYSICAL_IF}" -p tcp --dport 9000 -j DNAT --to-destination "${KEYCLOAK_IP}:9000" 2>/dev/null; then
    log "Adding port 9000 forwarding rule..."
    sudo iptables -t nat -A PREROUTING -i "${PHYSICAL_IF}" -p tcp --dport 9000 -j DNAT --to-destination "${KEYCLOAK_IP}:9000"
    
    # Save rules
    sudo mkdir -p /etc/iptables
    sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
    log "Port 9000 forwarding added and saved"
else
    log "Port 9000 forwarding already configured"
fi

echo ""
echo "=============================================="
echo "    Health Checks Enabled"
echo "=============================================="
echo "  Internal: http://localhost:9000/health/ready"
echo "  External: http://$(hostname -f):9000/health/ready"
echo ""
echo "Traefik can now use port 9000 for health checks."
echo "=============================================="

