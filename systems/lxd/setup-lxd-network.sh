#!/bin/bash
# =============================================================================
# LXD Network Setup Script (Identity Stack)
# =============================================================================
# Creates the lxdbr0 network with IPv4 configuration for identity containers.
# Uses 172.22.0.0/24 subnet (different from security-stack's 172.21.0.0/24)
#
# Usage: sudo ./setup-lxd-network.sh
# =============================================================================

set -euo pipefail

BRIDGE_NAME="lxdbr0"
IPV4_ADDRESS="172.22.0.1/24"
IPV4_DHCP_RANGES="172.22.0.50-172.22.0.200"

echo "=== LXD Network Setup (Identity Stack) ==="
echo "Bridge: ${BRIDGE_NAME}"
echo "IPv4: ${IPV4_ADDRESS}"
echo "DHCP Range: ${IPV4_DHCP_RANGES}"
echo ""

# =============================================================================
# Pre-flight Checks
# =============================================================================
echo "=== Pre-flight Checks ==="

# Ensure br_netfilter module is loaded
if ! lsmod | grep -q br_netfilter; then
    echo "Loading br_netfilter module..."
    sudo modprobe br_netfilter
    echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf
fi
echo "Checking br_netfilter module... OK"

# Ensure bridge-nf-call-iptables is enabled
if [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" != "1" ]]; then
    echo "Enabling net.bridge.bridge-nf-call-iptables..."
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
    echo "net.bridge.bridge-nf-call-iptables=1" | sudo tee /etc/sysctl.d/99-bridge-nf.conf
fi
echo "Checking bridge-nf-call-iptables... OK"

# =============================================================================
# Network Creation
# =============================================================================
echo ""
echo "=== Creating/Updating LXD Network ==="

if lxc network show "${BRIDGE_NAME}" >/dev/null 2>&1; then
    echo "Network ${BRIDGE_NAME} already exists. Updating configuration..."
    lxc network set "${BRIDGE_NAME}" ipv4.address="${IPV4_ADDRESS}"
    lxc network set "${BRIDGE_NAME}" ipv4.nat=true
    lxc network set "${BRIDGE_NAME}" ipv4.dhcp=true
    lxc network set "${BRIDGE_NAME}" ipv4.dhcp.ranges="${IPV4_DHCP_RANGES}"
    lxc network set "${BRIDGE_NAME}" ipv6.address=none
else
    echo "Creating network ${BRIDGE_NAME}..."
    lxc network create "${BRIDGE_NAME}" \
        ipv4.address="${IPV4_ADDRESS}" \
        ipv4.nat=true \
        ipv4.dhcp=true \
        ipv4.dhcp.ranges="${IPV4_DHCP_RANGES}" \
        ipv6.address=none
fi

echo "Network configuration complete."

# =============================================================================
# IP Forwarding
# =============================================================================
echo ""
echo "=== Configuring IP Forwarding ==="

if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
    echo "Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.d/99-ip-forward.conf
else
    echo "IP forwarding already enabled."
fi

# =============================================================================
# iptables FORWARD Rules
# =============================================================================
echo ""
echo "=== Setting up iptables FORWARD rules ==="

FORWARD_POLICY=$(sudo iptables -S FORWARD | grep -oP '^-P FORWARD \K\w+' || echo "UNKNOWN")
echo "Current FORWARD policy: ${FORWARD_POLICY}"

if [[ "${FORWARD_POLICY}" == "DROP" ]]; then
    echo "FORWARD policy is DROP. Adding explicit ACCEPT rules for ${BRIDGE_NAME}."

    if ! sudo iptables -C FORWARD -o "${BRIDGE_NAME}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        echo "Adding FORWARD rule for ${BRIDGE_NAME} output (ESTABLISHED)..."
        sudo iptables -I FORWARD -o "${BRIDGE_NAME}" -m state --state RELATED,ESTABLISHED -j ACCEPT
    else
        echo "FORWARD rule for ${BRIDGE_NAME} output (ESTABLISHED) already exists."
    fi

    if ! sudo iptables -C FORWARD -i "${BRIDGE_NAME}" -j ACCEPT 2>/dev/null; then
        echo "Adding FORWARD rule for ${BRIDGE_NAME} input..."
        sudo iptables -I FORWARD -i "${BRIDGE_NAME}" -j ACCEPT
    else
        echo "FORWARD rule for ${BRIDGE_NAME} input already exists."
    fi
else
    echo "FORWARD policy is not DROP. Existing rules should be sufficient."
fi

# =============================================================================
# NAT/MASQUERADE Rules
# =============================================================================
echo ""
echo "=== Verifying NAT/MASQUERADE rules ==="

SUBNET="${IPV4_ADDRESS%/*}"
SUBNET="${SUBNET%.*}.0/24"

if ! sudo iptables -t nat -C POSTROUTING -s "${SUBNET}" ! -o "${BRIDGE_NAME}" -j MASQUERADE 2>/dev/null; then
    echo "Adding MASQUERADE rule for ${SUBNET}..."
    sudo iptables -t nat -A POSTROUTING -s "${SUBNET}" ! -o "${BRIDGE_NAME}" -j MASQUERADE
else
    echo "MASQUERADE rule for ${SUBNET} already exists."
fi

# =============================================================================
# Persist iptables Rules
# =============================================================================
echo ""
echo "=== Making iptables rules persistent ==="

sudo mkdir -p /etc/iptables
sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
echo "Saved iptables rules to /etc/iptables/rules.v4"

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

# =============================================================================
# Verification
# =============================================================================
echo ""
echo "=== Final Verification ==="
echo ""
echo "Network configuration:"
lxc network show "${BRIDGE_NAME}"
echo ""
echo "Bridge status:"
ip link show "${BRIDGE_NAME}"
echo ""
echo "IP forwarding: $(sysctl -n net.ipv4.ip_forward)"
echo ""
echo "=== LXD Network Setup Complete ==="
echo ""
echo "NEXT STEPS:"
echo "1. Run setup-lxd-storage.sh"
echo "2. Run setup-lxd-profile.sh"

