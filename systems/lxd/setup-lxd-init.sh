#!/bin/bash
# =============================================================================
# LXD Initialization Script (Identity Stack)
# =============================================================================
# This script initializes LXD on a fresh installation.
# It should be run ONCE per host (idp001, idp002) before any other LXD setup.
#
# Usage: sudo ./setup-lxd-init.sh
# =============================================================================

set -euo pipefail

echo "=== LXD Initialization (Identity Stack) ==="

# Check if LXD is already initialized by looking for the local database
if [ -f "/var/snap/lxd/common/lxd/database/local.db" ]; then
    echo "LXD appears to be already initialized. Skipping 'lxd init'."
    echo "If you believe this is incorrect, you may need to purge LXD and reinstall."
else
    echo "LXD not initialized. Running 'lxd init --auto'..."
    sudo lxd init --auto
    echo "LXD initialization complete."
fi

echo ""
echo "=== Verifying LXD Status ==="
lxc config show || true
echo ""
echo "LXD initialization check complete."
echo ""
echo "NEXT STEPS:"
echo "1. Run setup-lxd-network.sh"
echo "2. Run setup-lxd-storage.sh"
echo "3. Run setup-lxd-profile.sh"

