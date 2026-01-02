#!/bin/bash
# =============================================================================
# Keycloak LXD Container Deployment Script
# =============================================================================
# Deploys Keycloak in an LXD container.
#
# Usage: sudo ./deploy-keycloak-container.sh
# =============================================================================

set -euo pipefail

CONTAINER_NAME="keycloak-lxc"
IMAGE="ubuntu:24.04"
STATIC_IP="172.22.0.10"
NETMASK="24"
GATEWAY="172.22.0.1"
DNS_SERVERS="192.168.1.4, 192.168.1.5"
BRIDGE_NAME="lxdbr0"
KEYCLOAK_VERSION="26.0.7"

echo "=== Keycloak LXD Container Deployment ==="
echo "Container: ${CONTAINER_NAME}"
echo "Static IP: ${STATIC_IP}/${NETMASK}"
echo "Keycloak Version: ${KEYCLOAK_VERSION}"
echo ""

# =============================================================================
# Pre-flight Checks
# =============================================================================
echo "=== Pre-flight Checks ==="

if ! lxc network show "${BRIDGE_NAME}" >/dev/null 2>&1; then
    echo "ERROR: LXD network ${BRIDGE_NAME} does not exist."
    exit 1
fi
echo "Checking LXD network... OK"

if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
    echo "ERROR: IP forwarding is not enabled."
    exit 1
fi
echo "Checking IP forwarding... OK"

if ! lxc profile show default | grep -q "eth0:"; then
    echo "ERROR: Default profile not configured."
    exit 1
fi
echo "Checking LXD profile... OK"

# Check PostgreSQL is available
if ! lxc exec postgres-lxc -- systemctl is-active postgresql >/dev/null 2>&1; then
    echo "WARNING: PostgreSQL container not running. Deploy it first."
    read -p "Continue anyway? (y/N): " -r
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

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
# Verify Bridge Attachment
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
    echo "Attaching ${HOST_VETH} to ${BRIDGE_NAME}..."
    sudo ip link set "${HOST_VETH}" master "${BRIDGE_NAME}"
    lxc restart "${CONTAINER_NAME}"
    sleep 5
fi
echo "Bridge attachment... OK"

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
# Install Dependencies and Keycloak
# =============================================================================
echo ""
echo "=== Installing Dependencies ==="

lxc exec "${CONTAINER_NAME}" -- apt-get update -qq
lxc exec "${CONTAINER_NAME}" -- apt-get upgrade -y -qq
lxc exec "${CONTAINER_NAME}" -- apt-get install -y openjdk-21-jre-headless curl unzip

echo "Verifying Java..."
lxc exec "${CONTAINER_NAME}" -- java --version

echo ""
echo "=== Installing Keycloak ==="

# Create keycloak user
lxc exec "${CONTAINER_NAME}" -- useradd --system --home /opt/keycloak --shell /usr/sbin/nologin keycloak || true

# Download Keycloak
lxc exec "${CONTAINER_NAME}" -- bash -c "
cd /tmp
curl -fsSLO https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz
tar xzf keycloak-${KEYCLOAK_VERSION}.tar.gz
mv keycloak-${KEYCLOAK_VERSION} /opt/keycloak
chown -R keycloak:keycloak /opt/keycloak
rm -f keycloak-${KEYCLOAK_VERSION}.tar.gz
"

echo "Keycloak installed to /opt/keycloak"

# =============================================================================
# Create Systemd Service
# =============================================================================
echo ""
echo "=== Creating Systemd Service ==="

lxc exec "${CONTAINER_NAME}" -- bash -c 'cat > /etc/systemd/system/keycloak.service << EOF
[Unit]
Description=Keycloak Identity Provider
After=network.target

[Service]
Type=exec
User=keycloak
Group=keycloak
WorkingDirectory=/opt/keycloak
Environment=KEYCLOAK_ADMIN=admin
EnvironmentFile=-/etc/keycloak/keycloak.env
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF'

# Create config directory
lxc exec "${CONTAINER_NAME}" -- mkdir -p /etc/keycloak

echo "Systemd service created (not started yet - needs configuration)"

echo ""
echo "=== Keycloak Container Deployed ==="
echo ""
echo "Container: ${CONTAINER_NAME}"
echo "IP: ${STATIC_IP}"
echo "Keycloak Version: ${KEYCLOAK_VERSION}"
echo "Install Path: /opt/keycloak"
echo ""
echo "NEXT STEPS:"
echo "1. Run ./configure-keycloak.sh to configure and start Keycloak"

