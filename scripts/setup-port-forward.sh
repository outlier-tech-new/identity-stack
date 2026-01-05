#!/bin/bash
# =============================================================================
# Port Forwarding Setup for Keycloak
# =============================================================================
# This script sets up iptables DNAT rules to forward traffic from the host's
# physical interface to the Keycloak LXD container.
#
# Usage: sudo ./setup-port-forward.sh
# =============================================================================

set -euo pipefail

# Configuration
KEYCLOAK_CONTAINER_IP="172.22.0.10"
KEYCLOAK_PORT="8080"
KEYCLOAK_MGMT_PORT="9000"

echo "=== Keycloak Port Forwarding Setup ==="

# Detect the primary physical interface
PHYSICAL_IF=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "${PHYSICAL_IF}" ]; then
    echo "ERROR: Could not detect physical interface."
    exit 1
fi
echo "Physical interface: ${PHYSICAL_IF}"

# Get the physical IP
PHYSICAL_IP=$(ip -4 addr show "${PHYSICAL_IF}" | grep -oP 'inet \K[0-9.]+' | head -1)
if [ -z "${PHYSICAL_IP}" ]; then
    echo "ERROR: Could not detect physical IP."
    exit 1
fi
echo "Physical IP: ${PHYSICAL_IP}"

echo ""
echo "=== Enabling IP Forwarding ==="
if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
    echo "Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.d/99-ip-forward.conf
else
    echo "IP forwarding already enabled."
fi

echo ""
echo "=== Configuring iptables DNAT ==="

# Keycloak main port (8080)
if ! sudo iptables -t nat -C PREROUTING -i "${PHYSICAL_IF}" -p tcp --dport "${KEYCLOAK_PORT}" -j DNAT --to-destination "${KEYCLOAK_CONTAINER_IP}:${KEYCLOAK_PORT}" 2>/dev/null; then
    echo "Adding DNAT rule for port ${KEYCLOAK_PORT}..."
    sudo iptables -t nat -A PREROUTING -i "${PHYSICAL_IF}" -p tcp --dport "${KEYCLOAK_PORT}" -j DNAT --to-destination "${KEYCLOAK_CONTAINER_IP}:${KEYCLOAK_PORT}"
else
    echo "DNAT rule for port ${KEYCLOAK_PORT} already exists."
fi

# Keycloak management port (9000) - for health checks
if ! sudo iptables -t nat -C PREROUTING -i "${PHYSICAL_IF}" -p tcp --dport "${KEYCLOAK_MGMT_PORT}" -j DNAT --to-destination "${KEYCLOAK_CONTAINER_IP}:${KEYCLOAK_MGMT_PORT}" 2>/dev/null; then
    echo "Adding DNAT rule for port ${KEYCLOAK_MGMT_PORT}..."
    sudo iptables -t nat -A PREROUTING -i "${PHYSICAL_IF}" -p tcp --dport "${KEYCLOAK_MGMT_PORT}" -j DNAT --to-destination "${KEYCLOAK_CONTAINER_IP}:${KEYCLOAK_MGMT_PORT}"
else
    echo "DNAT rule for port ${KEYCLOAK_MGMT_PORT} already exists."
fi

# FORWARD rules (if default policy is DROP)
FORWARD_POLICY=$(sudo iptables -S FORWARD | grep -oP '^-P FORWARD \K\w+' || echo "ACCEPT")
if [[ "${FORWARD_POLICY}" == "DROP" ]]; then
    echo ""
    echo "FORWARD policy is DROP. Adding explicit ACCEPT rules..."
    
    # Allow traffic to Keycloak container
    if ! sudo iptables -C FORWARD -d "${KEYCLOAK_CONTAINER_IP}" -p tcp --dport "${KEYCLOAK_PORT}" -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD -d "${KEYCLOAK_CONTAINER_IP}" -p tcp --dport "${KEYCLOAK_PORT}" -j ACCEPT
    fi
    if ! sudo iptables -C FORWARD -d "${KEYCLOAK_CONTAINER_IP}" -p tcp --dport "${KEYCLOAK_MGMT_PORT}" -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD -d "${KEYCLOAK_CONTAINER_IP}" -p tcp --dport "${KEYCLOAK_MGMT_PORT}" -j ACCEPT
    fi
fi

# MASQUERADE for responses
if ! sudo iptables -t nat -C POSTROUTING -s "${KEYCLOAK_CONTAINER_IP}" -j MASQUERADE 2>/dev/null; then
    echo "Adding MASQUERADE rule for ${KEYCLOAK_CONTAINER_IP}..."
    sudo iptables -t nat -A POSTROUTING -s "${KEYCLOAK_CONTAINER_IP}" -j MASQUERADE
else
    echo "MASQUERADE rule already exists."
fi

echo ""
echo "=== Making Rules Persistent ==="
sudo mkdir -p /etc/iptables
sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
echo "Saved rules to /etc/iptables/rules.v4"

# Create systemd service if not exists
if [ ! -f "/etc/systemd/system/iptables-restore.service" ]; then
    echo "Creating iptables-restore.service..."
    cat << 'EOF' | sudo tee /etc/systemd/system/iptables-restore.service >/dev/null
[Unit]
Description=Restore iptables rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore /etc/iptables/rules.v4
ExecStartPre=/bin/sleep 10
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable iptables-restore.service
    echo "Created and enabled iptables-restore.service"
else
    echo "iptables-restore.service already exists"
fi

echo ""
echo "=== Verification ==="
echo ""
echo "NAT PREROUTING rules:"
sudo iptables -t nat -L PREROUTING -n -v | grep -E "(${KEYCLOAK_PORT}|${KEYCLOAK_MGMT_PORT})" || echo "  (no rules found)"
echo ""
echo "NAT POSTROUTING rules:"
sudo iptables -t nat -L POSTROUTING -n -v | grep "${KEYCLOAK_CONTAINER_IP}" || echo "  (no rules found)"

echo ""
echo "=== Port Forwarding Complete ==="
echo ""
echo "External traffic to ${PHYSICAL_IP}:${KEYCLOAK_PORT} -> ${KEYCLOAK_CONTAINER_IP}:${KEYCLOAK_PORT}"
echo "External traffic to ${PHYSICAL_IP}:${KEYCLOAK_MGMT_PORT} -> ${KEYCLOAK_CONTAINER_IP}:${KEYCLOAK_MGMT_PORT}"
echo ""
echo "NEXT STEPS:"
echo "1. Add DNS record: idp001 IN A ${PHYSICAL_IP}"
echo "2. Test from sec001: curl http://${PHYSICAL_IP}:9000/health/ready"
echo "3. Update Traefik config if needed"

