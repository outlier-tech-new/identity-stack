#!/bin/bash
# =============================================================================
# Enable PostgreSQL Replication (Granular)
# =============================================================================
# Configures this node as a PRIMARY that can accept standby connections:
# 1. Enables port 5432 forwarding from host to PostgreSQL LXD container
# 2. Configures pg_hba.conf to allow replication from the OTHER node
# 3. Ensures replicator user exists
#
# Usage: sudo ./idp-enable-replication.sh
#
# This script should be run when:
# - Setting up initial primary
# - Promoting a standby to primary (called automatically by idp-promote-db.sh)
# =============================================================================

set -euo pipefail

PG_CONTAINER="postgres-lxc"
PG_PORT="5432"
PG_HBA="/etc/postgresql/16/main/pg_hba.conf"

# IDP node IPs - used for pg_hba.conf
IDP001_IP="192.168.1.13"
IDP002_IP="192.168.1.14"

log() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }
error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; exit 1; }

THIS_HOST=$(hostname -s)

echo "=============================================="
echo "    Enable PostgreSQL Replication"
echo "=============================================="
echo "  Host: ${THIS_HOST}"
echo "=============================================="

# Determine which node we are and which is the OTHER node
case "${THIS_HOST}" in
    idp001|idp01) OTHER_IP="${IDP002_IP}"; OTHER_NAME="idp002" ;;
    idp002|idp02) OTHER_IP="${IDP001_IP}"; OTHER_NAME="idp001" ;;
    *) error "Unknown host: ${THIS_HOST}. Expected idp001 or idp002." ;;
esac

# Get PostgreSQL container IP
POSTGRES_IP=$(lxc list ${PG_CONTAINER} -c4 --format csv 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
if [[ -z "${POSTGRES_IP}" ]]; then
    error "Could not determine PostgreSQL container IP"
fi
log "PostgreSQL container IP: ${POSTGRES_IP}"
log "Will allow replication from: ${OTHER_NAME} (${OTHER_IP})"

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

# =============================================================================
# Configure pg_hba.conf for replication
# =============================================================================
echo ""
log "Configuring pg_hba.conf for replication access..."

# Check if entry already exists for the OTHER node
if lxc exec ${PG_CONTAINER} -- grep -q "replication.*replicator.*${OTHER_IP}" ${PG_HBA} 2>/dev/null; then
    log "Replication entry for ${OTHER_IP} already exists in pg_hba.conf"
else
    log "Adding replication entry for ${OTHER_NAME} (${OTHER_IP})..."
    lxc exec ${PG_CONTAINER} -- bash -c "echo '# Allow replication from ${OTHER_NAME}' >> ${PG_HBA}"
    lxc exec ${PG_CONTAINER} -- bash -c "echo 'host replication replicator ${OTHER_IP}/32 scram-sha-256' >> ${PG_HBA}"
    
    # Reload PostgreSQL to pick up pg_hba.conf changes
    log "Reloading PostgreSQL configuration..."
    lxc exec ${PG_CONTAINER} -- sudo -u postgres psql -c "SELECT pg_reload_conf();" >/dev/null
    log "PostgreSQL configuration reloaded"
fi

# Verify pg_hba.conf
log "Current replication entries in pg_hba.conf:"
lxc exec ${PG_CONTAINER} -- grep -E "^host.*replication" ${PG_HBA} 2>/dev/null | sed 's/^/  /' || warn "No replication entries found"

# =============================================================================
# Summary
# =============================================================================
echo ""
log "Verification - iptables:"
iptables -t nat -L PREROUTING -n | grep ${PG_PORT} || warn "No PREROUTING rule found"

echo ""
echo "=============================================="
echo "    PostgreSQL Replication Enabled"
echo "=============================================="
echo "  This Node:  ${THIS_HOST} (PRIMARY)"
echo "  Accepts:    ${OTHER_NAME} (${OTHER_IP})"
echo ""
echo "  Port Forward: ${PHYSICAL_IP}:${PG_PORT} -> ${POSTGRES_IP}:${PG_PORT}"
echo ""
echo "Standbys can now connect for replication."
echo "=============================================="

