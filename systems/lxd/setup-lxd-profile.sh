#!/bin/bash
# =============================================================================
# LXD Profile Setup Script (Identity Stack)
# =============================================================================
# Configures the default LXD profile with storage and network devices.
#
# Usage: sudo ./setup-lxd-profile.sh
# =============================================================================

set -euo pipefail

PROFILE="default"
STORAGE_POOL="default"
NETWORK="lxdbr0"

echo "=== LXD Profile Setup (Identity Stack) ==="

# Add root disk if not present
if ! lxc profile device show "${PROFILE}" | grep -q "root:"; then
    echo "Adding root disk device to ${PROFILE} profile..."
    lxc profile device add "${PROFILE}" root disk path=/ pool="${STORAGE_POOL}"
else
    echo "Root disk device already configured."
fi

# Add eth0 network if not present
if ! lxc profile device show "${PROFILE}" | grep -q "eth0:"; then
    echo "Adding eth0 network device to ${PROFILE} profile..."
    lxc profile device add "${PROFILE}" eth0 nic network="${NETWORK}" name=eth0
else
    echo "eth0 network device already configured."
fi

echo ""
echo "=== Profile Configuration ==="
lxc profile show "${PROFILE}"
echo ""
echo "=== LXD Profile Setup Complete ==="
echo ""
echo "NEXT STEPS:"
echo "1. Deploy PostgreSQL: ./systems/postgres-lxd/deploy-postgres-container.sh"
echo "2. Deploy Keycloak: ./systems/keycloak-lxd/deploy-keycloak-container.sh"

