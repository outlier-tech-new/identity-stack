# IDP Stack Operator Manual

## Overview

The Identity Stack provides high-availability Keycloak backed by PostgreSQL with streaming replication. The stack runs across two nodes:

- **idp001** (192.168.1.13) - Can be PRIMARY or STANDBY
- **idp002** (192.168.1.14) - Can be PRIMARY or STANDBY

Traffic is routed through Traefik (sec001/sec002) which load-balances and health-checks both nodes.

## Architecture

```
                    ┌─────────────────┐
                    │   DNS: idp.*    │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  Traefik VIP    │
                    │  (sec001/002)   │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
     ┌────────▼────────┐           ┌────────▼────────┐
     │     idp001      │           │     idp002      │
     │  ┌───────────┐  │           │  ┌───────────┐  │
     │  │ Keycloak  │  │           │  │ Keycloak  │  │
     │  │   LXC     │  │           │  │   LXC     │  │
     │  └─────┬─────┘  │           │  └─────┬─────┘  │
     │        │        │           │        │        │
     │  ┌─────▼─────┐  │   WAL     │  ┌─────▼─────┐  │
     │  │ PostgreSQL│  │◄─────────►│  │ PostgreSQL│  │
     │  │  PRIMARY  │  │ streaming │  │  STANDBY  │  │
     │  └───────────┘  │           │  └───────────┘  │
     └─────────────────┘           └─────────────────┘
```

## Key Concepts

### PostgreSQL Roles
- **PRIMARY**: Accepts read/write, streams WAL to standby
- **STANDBY**: Read-only, receives WAL from primary, ready for promotion

### Keycloak Configuration
- Each Keycloak instance points to a database URL
- PRIMARY node's Keycloak → local PostgreSQL container
- STANDBY node's Keycloak → PRIMARY's PostgreSQL (via network)

### Health Checks
- Traefik checks `/health/ready` on port 9000 for each node
- Unhealthy nodes are automatically removed from load balancer
- Health endpoint reflects database connectivity status

---

## Daily Operations

### Check Status
```bash
# On any IDP node
./scripts/lib/idp-status.sh

# Output shows:
# - PostgreSQL: RUNNING/STOPPED, PRIMARY/STANDBY, standby count
# - Keycloak: RUNNING/STOPPED, database URL
# - Traefik: Whether this node is in the load balancer
```

### Verify Replication
```bash
# On PRIMARY - check connected standbys
lxc exec postgres-lxc -- sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"

# On STANDBY - check replication lag
lxc exec postgres-lxc -- sudo -u postgres psql -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();"
```

### View Logs
```bash
# Keycloak logs
lxc exec keycloak-lxc -- journalctl -u keycloak -f

# PostgreSQL logs
lxc exec postgres-lxc -- tail -f /var/log/postgresql/postgresql-16-main.log
```

---

## Failover Procedures

### Scenario 1: Emergency Failover (Primary has failed)

**Situation**: idp001 (PRIMARY) has failed. idp002 (STANDBY) needs to take over.

**Run on idp002 (the surviving STANDBY):**
```bash
cd /srv/identity-stack
sudo ./scripts/idp-failover.sh
```

**What this does:**
1. Promotes local PostgreSQL to PRIMARY
2. Enables replication port (5432) and configures pg_hba.conf
3. Switches local Keycloak to use local database
4. Removes the failed node from Traefik load balancer

**After the failed node is recovered:**
```bash
# On the recovered node (idp001)
cd /srv/identity-stack && git pull
export REPL_PASSWORD='<replication_password>'
sudo -E ./scripts/idp-reinstate.sh --standby-of idp02
```

### Scenario 2: Planned Role Switch (Both nodes healthy)

**Situation**: You want to swap PRIMARY/STANDBY roles for maintenance.

**Run on the CURRENT STANDBY (will become PRIMARY):**
```bash
cd /srv/identity-stack
export REPL_PASSWORD='<replication_password>'
sudo -E ./scripts/idp-role-switch.sh
```

**What this does:**
1. Verifies both nodes are healthy
2. Stops Keycloak on both nodes
3. Promotes this node to PRIMARY
4. Rebuilds the other node as STANDBY
5. Restarts Keycloak on both nodes
6. Updates Traefik configuration

### Scenario 3: Reinstate Failed Node as Standby

**Situation**: After a failover, the old PRIMARY needs to rejoin as STANDBY.

**Run on the node to reinstate:**
```bash
cd /srv/identity-stack && git pull
export REPL_PASSWORD='<replication_password>'
sudo -E ./scripts/idp-reinstate.sh --standby-of <current_primary>
```

**Example** (idp001 rejoining as standby of idp002):
```bash
sudo -E ./scripts/idp-reinstate.sh --standby-of idp02
```

**What this does:**
1. Verifies the specified primary is reachable
2. Stops local stack
3. Wipes local PostgreSQL data and rebuilds from primary
4. Configures Keycloak to point to primary's database
5. Starts the stack
6. Adds this node back to Traefik

---

## Granular Scripts (lib/)

For fine-grained control, use the individual scripts in `scripts/lib/`:

| Script | Purpose |
|--------|---------|
| `idp-status.sh` | Show status of all components |
| `idp-stop-stack.sh` | Stop Keycloak and PostgreSQL |
| `idp-start-stack.sh` | Start PostgreSQL and Keycloak |
| `idp-promote-db.sh` | Promote PostgreSQL to PRIMARY |
| `idp-rebuild-standby.sh` | Rebuild PostgreSQL as STANDBY |
| `idp-switch-db.sh` | Change Keycloak's database URL |
| `idp-enable-replication.sh` | Enable port forwarding and pg_hba.conf |
| `idp-enable-health.sh` | Enable Keycloak health endpoints |
| `idp-traefik-update.sh` | Add/remove node from Traefik |

### Example: Manual Step-by-Step Failover
```bash
# 1. Promote database
sudo ./scripts/lib/idp-promote-db.sh

# 2. Switch Keycloak to local database
sudo ./scripts/lib/idp-switch-db.sh --db-host local

# 3. Start stack
sudo ./scripts/lib/idp-start-stack.sh

# 4. Update Traefik (remove failed node)
# Run on sec001/sec002:
./add-idp-backend.sh remove idp01
```

---

## Traefik Integration

### Add/Remove Backend
On Traefik nodes (sec001/sec002):
```bash
cd /srv/security-stack/systems/traefik

# Add a backend
./add-idp-backend.sh add idp01

# Remove a backend
./add-idp-backend.sh remove idp01
```

### Verify Health Checks
```bash
# From Traefik node
curl -s http://idp01.outliertechnology.co.uk:9000/health/ready
curl -s http://idp02.outliertechnology.co.uk:9000/health/ready

# Should return: {"status": "UP", ...}
```

---

## Troubleshooting

### Keycloak Won't Start
```bash
# Check if database is accessible
lxc exec keycloak-lxc -- curl -v telnet://<db_host>:5432

# Check Keycloak configuration
lxc exec keycloak-lxc -- cat /opt/keycloak/conf/keycloak.conf

# Check Keycloak logs
lxc exec keycloak-lxc -- journalctl -u keycloak -n 100
```

### Replication Not Working
```bash
# On PRIMARY - check pg_hba.conf allows standby
lxc exec postgres-lxc -- grep replicator /etc/postgresql/16/main/pg_hba.conf

# Verify replicator user exists
lxc exec postgres-lxc -- sudo -u postgres psql -c "SELECT usename, userepl FROM pg_user WHERE usename='replicator';"

# Check port forwarding
sudo iptables -t nat -L PREROUTING -n | grep 5432
```

### Health Check Failing
```bash
# Check if Keycloak is running
lxc exec keycloak-lxc -- systemctl status keycloak

# Test health endpoint internally
lxc exec keycloak-lxc -- curl http://localhost:9000/health/ready

# Check port 9000 forwarding
sudo iptables -t nat -L PREROUTING -n | grep 9000
```

### Split-Brain Prevention
The system uses **manual failover** to prevent split-brain:
- PostgreSQL standbys cannot self-promote
- An operator must explicitly run failover scripts
- Traefik health checks prevent traffic to unhealthy nodes

---

## Credentials

### PostgreSQL Replication
- **User**: `replicator`
- **Password**: Stored in environment variable `REPL_PASSWORD`
- **Usage**: Set before running reinstate/rebuild scripts

### Keycloak Admin
- **Console**: https://idp.outliertechnology.co.uk/admin/
- **Realm**: master (initial)
- **Credentials**: Set during initial deployment

---

## Maintenance Windows

### Before Maintenance
1. Check current roles: `./scripts/lib/idp-status.sh`
2. If maintaining PRIMARY, perform planned role switch first
3. Document current state

### During Maintenance
- STANDBY can be taken offline without affecting service
- PRIMARY maintenance requires failover first

### After Maintenance
1. Reinstate node as STANDBY if needed
2. Verify replication: `./scripts/lib/idp-status.sh`
3. Confirm both nodes healthy in Traefik

---

## Backup and Recovery

### Database Backup (on PRIMARY)
```bash
lxc exec postgres-lxc -- sudo -u postgres pg_dump keycloak > keycloak_backup_$(date +%Y%m%d).sql
```

### Point-in-Time Recovery
With WAL archiving configured (future enhancement), PITR is possible. Currently, the standby provides real-time backup capability.

---

## Contact and Escalation

For issues beyond this manual:
1. Check PostgreSQL and Keycloak documentation
2. Review logs thoroughly before escalating
3. Document the exact error and steps taken

