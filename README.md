# Identity Stack

Identity and secrets management infrastructure for the homelab.

## Overview

This stack provides:
- **Keycloak**: Central Identity Provider (OIDC, SAML, user management)
- **OpenBao**: Secrets management (dynamic credentials, encryption, policies)

## Infrastructure

| Node | Hostname | IP | Role |
|------|----------|-----|------|
| Primary | idp001 | 192.168.1.13 | Active |
| Secondary | idp002 | 192.168.1.14 | Standby |

## LXD Containers

| Container | IP | Port | Purpose |
|-----------|-----|------|---------|
| keycloak-lxc | 172.22.0.10 | 8080 | Keycloak |
| postgres-lxc | 172.22.0.11 | 5432 | PostgreSQL (Keycloak DB) |
| openbao-lxc | 172.22.0.12 | 8200 | OpenBao Vault |

## Network

- LXD Bridge: `lxdbr0` (172.22.0.0/24)
- Gateway: 172.22.0.1
- Note: Different subnet from security-stack (172.21.x.x) to avoid conflicts

## Deployment Order

1. LXD setup (network, storage, profile)
2. PostgreSQL container (Keycloak database)
3. Keycloak container
4. OpenBao container (after Keycloak for OIDC auth)

## Quick Start

```bash
# On idp001:
cd /srv/identity-stack

# 1. Initialize LXD
sudo ./systems/lxd/setup-lxd-init.sh
sudo ./systems/lxd/setup-lxd-network.sh
sudo ./systems/lxd/setup-lxd-storage.sh
sudo ./systems/lxd/setup-lxd-profile.sh

# 2. Deploy PostgreSQL
sudo ./systems/postgres-lxd/deploy-postgres-container.sh
sudo ./systems/postgres-lxd/configure-postgres.sh

# 3. Deploy Keycloak
sudo ./systems/keycloak-lxd/deploy-keycloak-container.sh
sudo ./systems/keycloak-lxd/configure-keycloak.sh
```

## Documentation

- [Keycloak Setup](docs/keycloak-setup.md)
- [OpenBao Integration](docs/openbao-integration.md)
- [Authelia OIDC Integration](docs/authelia-oidc.md)

