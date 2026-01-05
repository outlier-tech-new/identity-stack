#!/bin/bash
# =============================================================================
# Enable PostgreSQL Replication Port (Granular)
# =============================================================================
# Enables port 5432 forwarding from host to PostgreSQL LXD container.
# This is required on the PRIMARY node so standbys can connect for replication.
#
# Usage: sudo ./idp-enable-replication.sh
#
# This script should be run when:
# - Setting up initial primary
# - Promoting a standby to primary
# =============================================================================

set -euo pipefail

PG_CONTAINER="postgres-lxc"
PG_PORT="5432"

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }

echo "=============================================="
echo "    Enable PostgreSQL Replication Port"
echo "=============================================="
echo "  Host: $(hostname -s)"
echo "=============================================="

# Get PostgreSQL container IP
POSTGRES_IP=$(lxc list ${PG_CONTAINER} -c4 --format csv 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
if [[ -z "${POSTGRES_IP}" ]]; then
    error "Could not determine PostgreSQL container IP"
fi
log "PostgreSQL container IP: ${POSTGRES_IP}"

# Detect physical interface
PHYSICAL_IF=$(ip route | grep default | awk '{print $5}' | head -1)
if [[ -z "${PHYSICAL_IF}" ]]; then
    error "Could not detect physical interface"
fi
log "Physical interface: ${PHYSICAL_IF}"

# Get physical IP for logging
PHYSICAL_IP=$(ip -4 addr show "${PHYSICAL_IF}" | grep -oP 'inet \K[0-9.]+' | head -1)

# Enable IP forwarding if not already
if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
    log "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-ip-forward.conf
fi

# Add PREROUTING DNAT rule for PostgreSQL
if ! iptables -t nat -C PREROUTING -i "${PHYSICAL_IF}" -p tcp --dport ${PG_PORT} -j DNAT --to-destination ${POSTGRES_IP}:${PG_PORT} 2>/dev/null; then
    log "Adding DNAT rule for port ${PG_PORT}..."
    iptables -t nat -A PREROUTING -i "${PHYSICAL_IF}" -p tcp --dport ${PG_PORT} -j DNAT --to-destination ${POSTGRES_IP}:${PG_PORT}
else
    log "DNAT rule for port ${PG_PORT} already exists"
fi

# Add FORWARD rule if default policy is DROP
FORWARD_POLICY=$(iptables -S FORWARD | grep -oP '^-P FORWARD \K\w+' || echo "ACCEPT")
if [[ "${FORWARD_POLICY}" == "DROP" ]]; then
    if ! iptables -C FORWARD -d ${POSTGRES_IP} -p tcp --dport ${PG_PORT} -j ACCEPT 2>/dev/null; then
        log "Adding FORWARD rule for port ${PG_PORT}..."
        iptables -I FORWARD -d ${POSTGRES_IP} -p tcp --dport ${PG_PORT} -j ACCEPT
    fi
fi

# Add MASQUERADE for responses if not exists
if ! iptables -t nat -C POSTROUTING -s ${POSTGRES_IP} -j MASQUERADE 2>/dev/null; then
    log "Adding MASQUERADE rule..."
    iptables -t nat -A POSTROUTING -s ${POSTGRES_IP} -j MASQUERADE
fi

# Save rules
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
log "Saved iptables rules"

# Verify
echo ""
log "Verification:"
iptables -t nat -L PREROUTING -n | grep ${PG_PORT} || warn "No PREROUTING rule found"

echo ""
echo "=============================================="
echo "    PostgreSQL Replication Port Enabled"
echo "=============================================="
echo "  External: ${PHYSICAL_IP}:${PG_PORT}"
echo "  Internal: ${POSTGRES_IP}:${PG_PORT}"
echo ""
echo "Standbys can now connect for replication."
echo "=============================================="

