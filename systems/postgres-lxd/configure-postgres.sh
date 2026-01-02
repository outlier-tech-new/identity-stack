#!/bin/bash
# =============================================================================
# PostgreSQL Configuration Script
# =============================================================================
# Configures PostgreSQL for Keycloak: creates database, user, and enables
# network access from the LXD subnet.
#
# Usage: sudo ./configure-postgres.sh
# =============================================================================

set -euo pipefail

CONTAINER_NAME="postgres-lxc"
KEYCLOAK_DB="keycloak"
KEYCLOAK_USER="keycloak"
POSTGRES_VERSION="16"
LXD_SUBNET="172.22.0.0/24"
BIND_IP="172.22.0.11"

echo "=== PostgreSQL Configuration ==="
echo ""

# Prompt for password
read -sp "Enter password for PostgreSQL user '${KEYCLOAK_USER}': " KEYCLOAK_PASSWORD
echo ""
read -sp "Confirm password: " KEYCLOAK_PASSWORD_CONFIRM
echo ""

if [[ "${KEYCLOAK_PASSWORD}" != "${KEYCLOAK_PASSWORD_CONFIRM}" ]]; then
    echo "ERROR: Passwords do not match."
    exit 1
fi

if [[ -z "${KEYCLOAK_PASSWORD}" ]]; then
    echo "ERROR: Password cannot be empty."
    exit 1
fi

# =============================================================================
# Create Database and User
# =============================================================================
echo ""
echo "=== Creating Database and User ==="

lxc exec "${CONTAINER_NAME}" -- sudo -u postgres psql -c "CREATE USER ${KEYCLOAK_USER} WITH PASSWORD '${KEYCLOAK_PASSWORD}';" 2>/dev/null || echo "User may already exist"
lxc exec "${CONTAINER_NAME}" -- sudo -u postgres psql -c "CREATE DATABASE ${KEYCLOAK_DB} OWNER ${KEYCLOAK_USER};" 2>/dev/null || echo "Database may already exist"
lxc exec "${CONTAINER_NAME}" -- sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${KEYCLOAK_DB} TO ${KEYCLOAK_USER};"

echo "Database '${KEYCLOAK_DB}' and user '${KEYCLOAK_USER}' configured."

# =============================================================================
# Configure Network Access
# =============================================================================
echo ""
echo "=== Configuring Network Access ==="

# Update postgresql.conf to listen on container IP
lxc exec "${CONTAINER_NAME}" -- bash -c "
sed -i \"s/#listen_addresses = 'localhost'/listen_addresses = 'localhost, ${BIND_IP}'/\" /etc/postgresql/${POSTGRES_VERSION}/main/postgresql.conf
"

# Update pg_hba.conf to allow connections from LXD subnet
lxc exec "${CONTAINER_NAME}" -- bash -c "
if ! grep -q '${LXD_SUBNET}' /etc/postgresql/${POSTGRES_VERSION}/main/pg_hba.conf; then
    echo '# Allow connections from LXD subnet' >> /etc/postgresql/${POSTGRES_VERSION}/main/pg_hba.conf
    echo 'host    ${KEYCLOAK_DB}    ${KEYCLOAK_USER}    ${LXD_SUBNET}    scram-sha-256' >> /etc/postgresql/${POSTGRES_VERSION}/main/pg_hba.conf
fi
"

# Restart PostgreSQL
echo "Restarting PostgreSQL..."
lxc exec "${CONTAINER_NAME}" -- systemctl restart postgresql

# =============================================================================
# Verify Configuration
# =============================================================================
echo ""
echo "=== Verifying Configuration ==="

# Test connection
echo "Testing database connection..."
lxc exec "${CONTAINER_NAME}" -- sudo -u postgres psql -d "${KEYCLOAK_DB}" -c "SELECT 1;" >/dev/null
echo "Local connection... OK"

# Check listening
LISTENING=$(lxc exec "${CONTAINER_NAME}" -- ss -tlnp | grep 5432 || true)
echo "PostgreSQL listening on:"
echo "${LISTENING}"

echo ""
echo "=== PostgreSQL Configuration Complete ==="
echo ""
echo "Database: ${KEYCLOAK_DB}"
echo "User: ${KEYCLOAK_USER}"
echo "Host: ${BIND_IP}"
echo "Port: 5432"
echo ""
echo "Connection string for Keycloak:"
echo "jdbc:postgresql://${BIND_IP}:5432/${KEYCLOAK_DB}"
echo ""
echo "NEXT STEPS:"
echo "1. Deploy Keycloak: ./systems/keycloak-lxd/deploy-keycloak-container.sh"

