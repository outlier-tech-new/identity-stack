#!/bin/bash
# =============================================================================
# PostgreSQL LXD Container Deployment Script
# =============================================================================
# Deploys PostgreSQL in an LXD container for Keycloak's database.
#
# Usage: sudo ./deploy-postgres-container.sh
# =============================================================================

set -euo pipefail

CONTAINER_NAME="postgres-lxc"
IMAGE="ubuntu:24.04"
STATIC_IP="172.22.0.11"
NETMASK="24"
GATEWAY="172.22.0.1"
DNS_SERVERS="192.168.1.4, 192.168.1.5"
BRIDGE_NAME="lxdbr0"
POSTGRES_VERSION="16"

echo "=== PostgreSQL LXD Container Deployment ==="
echo "Container: ${CONTAINER_NAME}"
echo "Static IP: ${STATIC_IP}/${NETMASK}"
echo "PostgreSQL Version: ${POSTGRES_VERSION}"
echo ""

# =============================================================================
# Pre-flight Checks
# =============================================================================
echo "=== Pre-flight Checks ==="

if ! lxc network show "${BRIDGE_NAME}" >/dev/null 2>&1; then
    echo "ERROR: LXD network ${BRIDGE_NAME} does not exist. Run setup-lxd-network.sh first."
    exit 1
fi
echo "Checking LXD network... OK"

if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
    echo "ERROR: IP forwarding is not enabled."
    exit 1
fi
echo "Checking IP forwarding... OK"

if ! lxc profile show default | grep -q "eth0:"; then
    echo "ERROR: Default profile not configured. Run setup-lxd-profile.sh first."
    exit 1
fi
echo "Checking LXD profile... OK"

# =============================================================================
# Container Deployment
# =============================================================================
echo ""
echo "=== Deploying Container ==="

if lxc info "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "Container ${CONTAINER_NAME} already exists."
    read -p "Delete and recreate? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        lxc stop "${CONTAINER_NAME}" --force 2>/dev/null || true
        lxc delete "${CONTAINER_NAME}" --force 2>/dev/null || true
    else
        echo "Aborting."
        exit 1
    fi
fi

echo "Launching ${CONTAINER_NAME}..."
lxc launch "${IMAGE}" "${CONTAINER_NAME}"

echo "Waiting for container to start..."
sleep 3

echo "Waiting for cloud-init..."
lxc exec "${CONTAINER_NAME}" -- cloud-init status --wait || true

# =============================================================================
# Configure Static IP
# =============================================================================
echo ""
echo "=== Configuring Static IP ==="

lxc exec "${CONTAINER_NAME}" -- bash -c "cat > /etc/netplan/50-static.yaml << 'EOF'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      addresses:
        - ${STATIC_IP}/${NETMASK}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS_SERVERS}]
EOF"

lxc exec "${CONTAINER_NAME}" -- chmod 600 /etc/netplan/50-static.yaml
lxc exec "${CONTAINER_NAME}" -- netplan apply
sleep 2

ASSIGNED_IP=$(lxc exec "${CONTAINER_NAME}" -- ip -4 addr show eth0 | grep -oP 'inet \K[0-9.]+' | head -1)
if [[ "${ASSIGNED_IP}" != "${STATIC_IP}" ]]; then
    echo "ERROR: IP mismatch. Expected ${STATIC_IP}, got ${ASSIGNED_IP}"
    exit 1
fi
echo "Static IP configured: ${ASSIGNED_IP}"

# =============================================================================
# Verify/Fix Bridge Attachment (AFTER netplan, which can break it)
# =============================================================================
echo ""
echo "=== Verifying Bridge Attachment ==="

HOST_VETH=$(lxc info "${CONTAINER_NAME}" | grep "Host interface:" | awk '{print $3}')
if [ -z "${HOST_VETH}" ]; then
    echo "ERROR: Could not determine host veth interface."
    exit 1
fi
echo "Container veth: ${HOST_VETH}"

if ! bridge link show | grep -q "${HOST_VETH}.*master ${BRIDGE_NAME}"; then
    echo "Veth NOT attached to bridge. Attaching ${HOST_VETH} to ${BRIDGE_NAME}..."
    sudo ip link set "${HOST_VETH}" master "${BRIDGE_NAME}"
    sleep 1
    if ! bridge link show | grep -q "${HOST_VETH}.*master ${BRIDGE_NAME}"; then
        echo "ERROR: Failed to attach veth to bridge."
        exit 1
    fi
    echo "Attached successfully."
else
    echo "Bridge attachment... OK"
fi

# =============================================================================
# Connectivity Test
# =============================================================================
echo ""
echo "=== Connectivity Test ==="

for target in "${GATEWAY}" "8.8.8.8" "google.com"; do
    if lxc exec "${CONTAINER_NAME}" -- ping -c 2 "${target}" >/dev/null 2>&1; then
        echo "Ping ${target}... OK"
    else
        echo "Ping ${target}... FAILED"
        exit 1
    fi
done

# =============================================================================
# Install PostgreSQL
# =============================================================================
echo ""
echo "=== Installing PostgreSQL ==="

lxc exec "${CONTAINER_NAME}" -- apt-get update -qq
lxc exec "${CONTAINER_NAME}" -- apt-get upgrade -y -qq
lxc exec "${CONTAINER_NAME}" -- apt-get install -y postgresql-${POSTGRES_VERSION}

echo "Verifying installation..."
lxc exec "${CONTAINER_NAME}" -- psql --version

echo ""
echo "=== PostgreSQL Container Deployed ==="
echo ""
echo "Container: ${CONTAINER_NAME}"
echo "IP: ${STATIC_IP}"
echo "PostgreSQL Version: ${POSTGRES_VERSION}"
echo ""
echo "NEXT STEPS:"
echo "1. Run ./configure-postgres.sh to create Keycloak database"

