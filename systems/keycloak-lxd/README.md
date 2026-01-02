# Keycloak LXD Deployment

Keycloak Identity Provider for centralized authentication.

## Container Details

- **Container**: keycloak-lxc
- **IP**: 172.22.0.10
- **Port**: 8080
- **Version**: 26.0.7

## Prerequisites

- PostgreSQL container deployed and configured
- LXD network and profile configured

## Deployment

```bash
# Deploy container
sudo ./deploy-keycloak-container.sh

# Configure Keycloak (prompts for passwords)
sudo ./configure-keycloak.sh
```

## Access

| Endpoint | URL |
|----------|-----|
| Health | http://172.22.0.10:8080/health/ready |
| Admin Console | http://172.22.0.10:8080/admin |
| Account Console | http://172.22.0.10:8080/realms/{realm}/account |

## Verification

```bash
# Check service status
lxc exec keycloak-lxc -- systemctl status keycloak

# View logs
lxc exec keycloak-lxc -- journalctl -u keycloak -f

# Health check
lxc exec keycloak-lxc -- curl http://localhost:8080/health/ready
```

## Integration

### Traefik Route

Add to `security-stack/systems/traefik/dynamic/keycloak.yml`:

```yaml
http:
  routers:
    keycloak:
      rule: "Host(`idp.outliertechnology.co.uk`)"
      entryPoints:
        - websecure
      service: keycloak
      tls:
        certResolver: stepca

  services:
    keycloak:
      loadBalancer:
        servers:
          - url: "http://172.22.0.10:8080"
```

### Authelia OIDC

After creating a realm and client in Keycloak, configure Authelia:

```yaml
identity_providers:
  oidc:
    - id: keycloak
      description: Keycloak
      issuer: https://idp.outliertechnology.co.uk/realms/homelab
      client_id: authelia
      client_secret: <secret>
```

## Configuration Files

| File | Purpose |
|------|---------|
| /opt/keycloak/conf/keycloak.conf | Main configuration |
| /etc/keycloak/keycloak.env | Secrets (admin password, DB password) |
| /etc/systemd/system/keycloak.service | Systemd service |

