#!/bin/bash
# =============================================================================
# LXD Storage Setup Script (Identity Stack)
# =============================================================================
# Creates a directory-based storage pool for identity containers.
#
# Usage: sudo ./setup-lxd-storage.sh
# =============================================================================

set -euo pipefail

STORAGE_POOL="default"

echo "=== LXD Storage Setup (Identity Stack) ==="

if lxc storage show "${STORAGE_POOL}" >/dev/null 2>&1; then
    echo "Storage pool '${STORAGE_POOL}' already exists."
    lxc storage show "${STORAGE_POOL}"
else
    echo "Creating storage pool '${STORAGE_POOL}'..."
    lxc storage create "${STORAGE_POOL}" dir
    echo "Storage pool created."
fi

echo ""
echo "=== Storage Pool Status ==="
lxc storage list
echo ""
echo "=== LXD Storage Setup Complete ==="
echo ""
echo "NEXT STEPS:"
echo "1. Run setup-lxd-profile.sh"

