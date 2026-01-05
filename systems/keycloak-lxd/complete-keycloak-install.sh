#!/bin/bash
# =============================================================================
# Complete Keycloak Installation
# =============================================================================
# Use this script if deploy-keycloak-container.sh failed partway through
# but the container is running with networking fixed.
#
# This script completes:
# - Keycloak binary download & install
# - Systemd service creation
#
# Usage: sudo ./complete-keycloak-install.sh
# =============================================================================

set -euo pipefail

CONTAINER_NAME="keycloak-lxc"
KEYCLOAK_VERSION="26.0.7"

echo "=== Completing Keycloak Installation ==="
echo "Container: ${CONTAINER_NAME}"
echo "Keycloak Version: ${KEYCLOAK_VERSION}"
echo ""

# Check container exists and is running
if ! lxc info "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "ERROR: Container ${CONTAINER_NAME} does not exist."
    exit 1
fi

STATE=$(lxc info "${CONTAINER_NAME}" | grep "Status:" | awk '{print $2}')
if [[ "${STATE}" != "RUNNING" ]]; then
    echo "ERROR: Container is not running (status: ${STATE})"
    exit 1
fi
echo "Container status: ${STATE}"

# Check connectivity
echo ""
echo "=== Verifying Connectivity ==="
if ! lxc exec "${CONTAINER_NAME}" -- ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "ERROR: Container has no internet connectivity. Fix networking first."
    exit 1
fi
echo "Internet connectivity... OK"

# Check Java is installed
echo ""
echo "=== Checking Java ==="
if ! lxc exec "${CONTAINER_NAME}" -- java --version >/dev/null 2>&1; then
    echo "Java not installed. Installing..."
    lxc exec "${CONTAINER_NAME}" -- apt-get update -qq
    lxc exec "${CONTAINER_NAME}" -- apt-get install -y openjdk-21-jre-headless curl unzip
fi
lxc exec "${CONTAINER_NAME}" -- java --version

# Check if Keycloak is already installed
echo ""
echo "=== Installing Keycloak ==="
if lxc exec "${CONTAINER_NAME}" -- test -d /opt/keycloak/bin 2>/dev/null; then
    echo "Keycloak already installed at /opt/keycloak"
else
    # Create keycloak user
    lxc exec "${CONTAINER_NAME}" -- useradd --system --home /opt/keycloak --shell /usr/sbin/nologin keycloak 2>/dev/null || true

    # Download and install Keycloak
    echo "Downloading Keycloak ${KEYCLOAK_VERSION}..."
    lxc exec "${CONTAINER_NAME}" -- bash -c "
cd /tmp
curl -fsSLO https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz
echo 'Extracting...'
tar xzf keycloak-${KEYCLOAK_VERSION}.tar.gz
mv keycloak-${KEYCLOAK_VERSION} /opt/keycloak
chown -R keycloak:keycloak /opt/keycloak
rm -f keycloak-${KEYCLOAK_VERSION}.tar.gz
"
    echo "Keycloak installed to /opt/keycloak"
fi

# Create systemd service if not exists
echo ""
echo "=== Creating Systemd Service ==="
if lxc exec "${CONTAINER_NAME}" -- test -f /etc/systemd/system/keycloak.service 2>/dev/null; then
    echo "Systemd service already exists"
else
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
    echo "Systemd service created"
fi

# Create config directory
lxc exec "${CONTAINER_NAME}" -- mkdir -p /etc/keycloak

echo ""
echo "=== Keycloak Installation Complete ==="
echo ""
echo "Keycloak Version: ${KEYCLOAK_VERSION}"
echo "Install Path: /opt/keycloak"
echo ""
echo "NEXT STEPS:"
echo "1. Run ./configure-keycloak.sh to configure database and start Keycloak"

