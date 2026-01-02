#!/bin/bash
# =============================================================================
# Keycloak Configuration Script
# =============================================================================
# Configures Keycloak with PostgreSQL database, builds optimized distribution,
# and starts the service.
#
# Usage: sudo ./configure-keycloak.sh
# =============================================================================

set -euo pipefail

CONTAINER_NAME="keycloak-lxc"
KEYCLOAK_IP="172.22.0.10"
POSTGRES_IP="172.22.0.11"
POSTGRES_DB="keycloak"
POSTGRES_USER="keycloak"
KEYCLOAK_HOSTNAME="idp.outliertechnology.co.uk"

echo "=== Keycloak Configuration ==="
echo ""

# =============================================================================
# Collect Secrets
# =============================================================================
read -sp "Enter Keycloak admin password: " KEYCLOAK_ADMIN_PASSWORD
echo ""
read -sp "Confirm Keycloak admin password: " KEYCLOAK_ADMIN_PASSWORD_CONFIRM
echo ""

if [[ "${KEYCLOAK_ADMIN_PASSWORD}" != "${KEYCLOAK_ADMIN_PASSWORD_CONFIRM}" ]]; then
    echo "ERROR: Passwords do not match."
    exit 1
fi

echo ""
read -sp "Enter PostgreSQL password for '${POSTGRES_USER}': " POSTGRES_PASSWORD
echo ""

# =============================================================================
# Test PostgreSQL Connection
# =============================================================================
echo ""
echo "=== Testing PostgreSQL Connection ==="

if lxc exec "${CONTAINER_NAME}" -- bash -c "
    apt-get install -y -qq postgresql-client >/dev/null 2>&1
    PGPASSWORD='${POSTGRES_PASSWORD}' psql -h ${POSTGRES_IP} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT 1;' >/dev/null 2>&1
"; then
    echo "PostgreSQL connection... OK"
else
    echo "ERROR: Cannot connect to PostgreSQL at ${POSTGRES_IP}"
    exit 1
fi

# =============================================================================
# Configure Keycloak
# =============================================================================
echo ""
echo "=== Configuring Keycloak ==="

# Create environment file with secrets
lxc exec "${CONTAINER_NAME}" -- bash -c "cat > /etc/keycloak/keycloak.env << EOF
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
KC_DB_PASSWORD=${POSTGRES_PASSWORD}
EOF"
lxc exec "${CONTAINER_NAME}" -- chmod 600 /etc/keycloak/keycloak.env
lxc exec "${CONTAINER_NAME}" -- chown keycloak:keycloak /etc/keycloak/keycloak.env

# Create keycloak.conf
lxc exec "${CONTAINER_NAME}" -- bash -c "cat > /opt/keycloak/conf/keycloak.conf << EOF
# Database
db=postgres
db-url=jdbc:postgresql://${POSTGRES_IP}:5432/${POSTGRES_DB}
db-username=${POSTGRES_USER}
# Password loaded from environment variable KC_DB_PASSWORD

# HTTP
http-enabled=true
http-port=8080
http-host=0.0.0.0

# Hostname (for production, set your actual hostname)
hostname=${KEYCLOAK_HOSTNAME}
hostname-strict=false

# Proxy (Traefik terminates TLS)
proxy-headers=xforwarded

# Health
health-enabled=true
metrics-enabled=true

# Logging
log=console
log-level=info
EOF"

lxc exec "${CONTAINER_NAME}" -- chown keycloak:keycloak /opt/keycloak/conf/keycloak.conf

# =============================================================================
# Build Optimized Distribution
# =============================================================================
echo ""
echo "=== Building Optimized Keycloak ==="
echo "This may take a few minutes..."

lxc exec "${CONTAINER_NAME}" -- sudo -u keycloak /opt/keycloak/bin/kc.sh build

# =============================================================================
# Start Keycloak
# =============================================================================
echo ""
echo "=== Starting Keycloak ==="

lxc exec "${CONTAINER_NAME}" -- systemctl daemon-reload
lxc exec "${CONTAINER_NAME}" -- systemctl enable keycloak
lxc exec "${CONTAINER_NAME}" -- systemctl start keycloak

# Wait for startup
echo "Waiting for Keycloak to start..."
for i in {1..30}; do
    if lxc exec "${CONTAINER_NAME}" -- curl -sf http://localhost:8080/health/ready >/dev/null 2>&1; then
        echo "Keycloak is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "WARNING: Keycloak may not be ready. Check logs with:"
        echo "  lxc exec ${CONTAINER_NAME} -- journalctl -u keycloak -f"
    fi
    sleep 5
done

# =============================================================================
# Verify
# =============================================================================
echo ""
echo "=== Verification ==="

lxc exec "${CONTAINER_NAME}" -- systemctl status keycloak --no-pager || true

echo ""
echo "Health check:"
lxc exec "${CONTAINER_NAME}" -- curl -sf http://localhost:8080/health/ready && echo " (ready)" || echo " (not ready)"

echo ""
echo "=== Keycloak Configuration Complete ==="
echo ""
echo "Keycloak URL: http://${KEYCLOAK_IP}:8080"
echo "Admin Console: http://${KEYCLOAK_IP}:8080/admin"
echo "Admin User: admin"
echo ""
echo "NEXT STEPS:"
echo "1. Add Traefik route for https://${KEYCLOAK_HOSTNAME}"
echo "2. Create realm and configure OIDC clients"
echo "3. Integrate with Authelia"

