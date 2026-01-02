# PostgreSQL LXD Deployment

PostgreSQL database for Keycloak.

## Container Details

- **Container**: postgres-lxc
- **IP**: 172.22.0.11
- **Port**: 5432
- **Version**: PostgreSQL 16

## Deployment

```bash
# Deploy container
sudo ./deploy-postgres-container.sh

# Configure database (prompts for password)
sudo ./configure-postgres.sh
```

## Database Configuration

| Setting | Value |
|---------|-------|
| Database | keycloak |
| User | keycloak |
| Host | 172.22.0.11 |
| Port | 5432 |

## Connection String

```
jdbc:postgresql://172.22.0.11:5432/keycloak
```

## Verification

```bash
# Check PostgreSQL is running
lxc exec postgres-lxc -- systemctl status postgresql

# Test connection
lxc exec postgres-lxc -- sudo -u postgres psql -d keycloak -c "SELECT 1;"

# Check listening ports
lxc exec postgres-lxc -- ss -tlnp | grep 5432
```

