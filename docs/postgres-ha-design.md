# PostgreSQL High Availability Design for Keycloak

## Document Info
- **Status**: Draft - Awaiting Review
- **Created**: 2026-01-05
- **Author**: Infrastructure Team
- **Related**: Identity Stack (idp001, idp002)

---

## Problem Statement

The current identity stack deployment has **independent PostgreSQL instances** on each IDP node:

```
idp001                          idp002
├── keycloak-lxc               ├── keycloak-lxc
│   └── Keycloak ────────►     │   └── Keycloak ────────►
└── postgres-lxc               └── postgres-lxc
    └── DB (independent)           └── DB (independent)
```

**Issues with current setup:**
1. Users/realms created on idp001 don't exist on idp002
2. Sessions are not shared between nodes
3. Configuration changes don't replicate
4. Load balancing will cause inconsistent user experience
5. No database redundancy - losing either DB loses that node's data

---

## Requirements

| Requirement | Priority | Notes |
|-------------|----------|-------|
| Database replication | Must Have | All writes replicated to standby |
| Automatic failover | Should Have | Minimize downtime on primary failure |
| Read scaling | Nice to Have | Standby can serve read queries |
| Simple operations | Must Have | Easy to understand and troubleshoot |
| LXD compatible | Must Have | Must work within existing LXD containers |

---

## Option 1: pg_auto_failover (Recommended)

### Overview
Microsoft's [pg_auto_failover](https://github.com/hapostgres/pg_auto_failover) provides automatic failover with minimal configuration. It uses a "monitor" node to track cluster health and coordinate failover.

### Architecture

```
                ┌───────────────────────────────────┐
                │           Monitor Node            │
                │   (runs on sec001 or separate)    │
                │   Tracks health, triggers failover│
                └───────────────┬───────────────────┘
                                │
           ┌────────────────────┴────────────────────┐
           │                                         │
   ┌───────▼───────┐                       ┌─────────▼─────────┐
   │   idp001      │                       │      idp002       │
   │ postgres-lxc  │◄─────────────────────►│   postgres-lxc    │
   │   PRIMARY     │  streaming replication│     SECONDARY     │
   │               │                       │   (hot standby)   │
   └───────────────┘                       └───────────────────┘
           │                                         │
           └────────────────┬────────────────────────┘
                            │
                ┌───────────▼───────────┐
                │   pg-idp.internal     │
                │   (DNS or libpq URI)  │
                │   → routes to PRIMARY │
                └───────────────────────┘
                            │
           ┌────────────────┴────────────────────┐
           │                                     │
   ┌───────▼───────┐                   ┌─────────▼─────────┐
   │   Keycloak    │                   │     Keycloak      │
   │   (idp001)    │                   │     (idp002)      │
   └───────────────┘                   └───────────────────┘
```

### Pros
- Simple to set up (single binary, minimal config)
- Automatic health checks and failover
- Built-in connection routing via `pg_autoctl` proxy
- Good documentation
- Actively maintained

### Cons
- Requires monitor node (can run on existing server)
- Relatively new compared to Patroni
- Fewer community resources

### Components Needed
1. **Monitor**: Lightweight process tracking cluster state
2. **Primary node**: Existing postgres-lxc on idp001
3. **Secondary node**: Existing postgres-lxc on idp002
4. **Connection string**: Updated to use failover-aware URI

### Estimated Effort
- Initial setup: 2-4 hours
- Testing: 2-3 hours
- Documentation: 1 hour

---

## Option 2: Patroni + etcd

### Overview
[Patroni](https://github.com/patroni/patroni) is the industry standard for PostgreSQL HA. It uses a distributed consensus store (etcd, Consul, or ZooKeeper) to manage leader election and cluster state.

### Architecture

```
   ┌─────────────────────────────────────────────────────┐
   │                    etcd cluster                      │
   │   (3 nodes for quorum - can run on sec001/002/idp)  │
   └─────────────────────────┬───────────────────────────┘
                             │
        ┌────────────────────┴────────────────────┐
        │                                         │
┌───────▼───────┐                       ┌─────────▼─────────┐
│   Patroni     │                       │      Patroni      │
│   (idp001)    │◄─────────────────────►│      (idp002)     │
│   PRIMARY     │  streaming replication│     REPLICA       │
└───────────────┘                       └───────────────────┘
        │                                         │
        └────────────────┬────────────────────────┘
                         │
             ┌───────────▼───────────┐
             │   HAProxy / PgBouncer │
             │   (connection routing)│
             └───────────────────────┘
```

### Pros
- Industry standard, battle-tested at scale
- Very robust failover logic
- Extensive configuration options
- Large community and documentation
- Supports complex topologies (cascading replicas, etc.)

### Cons
- Requires etcd/Consul cluster (3+ nodes for HA)
- More moving parts to manage
- Higher complexity for 2-node setup
- Needs connection pooler (HAProxy/PgBouncer) for routing

### Components Needed
1. **etcd cluster**: 3 nodes (can colocate on existing servers)
2. **Patroni agent**: Runs alongside each Postgres
3. **HAProxy/PgBouncer**: Routes connections to current leader
4. **Updated connection strings**: Point to HAProxy

### Estimated Effort
- Initial setup: 4-6 hours
- Testing: 3-4 hours
- Documentation: 2 hours

---

## Option 3: repmgr + Keepalived

### Overview
[repmgr](https://repmgr.org/) is a mature replication manager with automatic failover capabilities. Combined with Keepalived, it can provide a floating VIP for database access.

### Architecture

```
           ┌─────────────────────────────────────────────┐
           │         Floating VIP: 172.22.0.100          │
           │   (managed by Keepalived between nodes)     │
           └─────────────────────┬───────────────────────┘
                                 │
        ┌────────────────────────┴────────────────────┐
        │                                             │
┌───────▼───────┐                           ┌─────────▼─────────┐
│   repmgrd     │                           │      repmgrd      │
│   (idp001)    │◄─────────────────────────►│      (idp002)     │
│   PRIMARY     │  streaming replication    │     STANDBY       │
│   VIP holder  │                           │                   │
└───────────────┘                           └───────────────────┘
```

### Pros
- Mature and well-documented
- Simple VIP-based routing (no extra components)
- Works well in 2-node setups
- Lightweight

### Cons
- Witness node recommended to avoid split-brain
- Manual intervention sometimes needed
- Less sophisticated than Patroni

### Components Needed
1. **repmgr**: Installed on both Postgres nodes
2. **Keepalived**: Manages floating VIP
3. **Witness node** (optional): Prevents split-brain
4. **Updated connection strings**: Point to VIP

### Estimated Effort
- Initial setup: 3-4 hours
- Testing: 2-3 hours
- Documentation: 1 hour

---

## Option 4: Manual Streaming Replication + Scripted Failover

### Overview
Basic PostgreSQL streaming replication with manual or scripted failover. Simplest to set up, but requires intervention when primary fails.

### Architecture

```
┌───────────────┐                       ┌───────────────────┐
│   postgres    │                       │      postgres     │
│   (idp001)    │──────────────────────►│      (idp002)     │
│   PRIMARY     │  streaming replication│     STANDBY       │
└───────────────┘                       └───────────────────┘
        │
        │ Keycloak connects directly
        │ (manual failover to standby if needed)
        ▼
┌───────────────┐
│   Keycloak    │
│   (both nodes)│
└───────────────┘
```

### Pros
- Simplest to set up
- No additional components
- Native PostgreSQL features only
- Easy to understand

### Cons
- **Manual failover required** (or basic scripting)
- Downtime during failover
- Risk of human error
- Connection string must be updated manually

### Components Needed
1. **Streaming replication config**: pg_hba.conf, recovery.conf
2. **Failover script**: Manual promotion and DNS/config update
3. **Monitoring**: To detect primary failure

### Estimated Effort
- Initial setup: 1-2 hours
- Failover scripting: 1-2 hours
- Documentation: 1 hour

---

## Comparison Matrix

| Criteria | pg_auto_failover | Patroni + etcd | repmgr + Keepalived | Manual |
|----------|------------------|----------------|---------------------|--------|
| **Complexity** | Medium | High | Medium | Low |
| **Auto Failover** | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No |
| **Extra Components** | Monitor only | etcd + HAProxy | Keepalived + witness | None |
| **Split-brain Protection** | ✅ Good | ✅ Excellent | ⚠️ Needs witness | ❌ None |
| **LXD Compatibility** | ✅ Easy | ⚠️ Needs planning | ✅ Easy | ✅ Easy |
| **Community Support** | Good | Excellent | Good | N/A |
| **Setup Time** | 2-4 hours | 4-6 hours | 3-4 hours | 1-2 hours |
| **Operational Overhead** | Low | Medium | Low | High |

---

## Recommendation

### For This Environment: **Option 1 - pg_auto_failover**

**Rationale:**
1. **Right-sized complexity** - Not overkill for a 2-node setup
2. **Automatic failover** - Critical for true HA
3. **Minimal components** - Just the monitor node
4. **LXD friendly** - Can run in existing containers
5. **Good documentation** - Easy to troubleshoot

### Implementation Plan

#### Phase 1: Preparation
1. Back up existing databases on both nodes
2. Document current Keycloak connection strings
3. Create DNS entry: `pg-idp.lan.outliertechnology.co.uk`

#### Phase 2: Monitor Setup
1. Choose monitor location (recommend: sec001 or dedicated LXD container)
2. Install pg_auto_failover on monitor
3. Initialize monitor node

#### Phase 3: Primary Conversion
1. Stop Keycloak on idp001
2. Install pg_auto_failover extension
3. Register postgres-lxc (idp001) as primary with monitor
4. Verify replication is ready

#### Phase 4: Secondary Conversion
1. Stop Keycloak on idp002
2. **Drop or backup** the independent database (it will be replaced)
3. Install pg_auto_failover extension
4. Register postgres-lxc (idp002) as secondary
5. Verify streaming replication is working

#### Phase 5: Keycloak Configuration
1. Update Keycloak connection strings on both nodes:
   ```
   # Before
   db-url=jdbc:postgresql://172.22.0.11:5432/keycloak
   
   # After (failover-aware URI)
   db-url=jdbc:postgresql://pg-idp.lan.outliertechnology.co.uk:5432/keycloak?target_session_attrs=read-write
   ```
2. Start Keycloak on both nodes
3. Verify both can connect and serve requests

#### Phase 6: Testing
1. Create test user on Keycloak - verify it appears on both nodes
2. Simulate primary failure - verify automatic failover
3. Restore original primary - verify it rejoins as secondary
4. Document runbooks for operations team

---

## Open Questions

1. **Where should the monitor run?**
   - Option A: On sec001 (co-located with Traefik)
   - Option B: Dedicated LXD container on idp001 or idp002
   - Option C: Separate VM/host

2. **DNS or direct connection routing?**
   - DNS entry updated on failover (simpler)
   - pg_auto_failover's built-in proxy (more integrated)

3. **What happens to idp002's existing Keycloak data?**
   - If any configuration was done on idp002, it will be lost
   - Need to verify idp002 is "clean" or export any needed config first

4. **Backup strategy for the replicated cluster?**
   - pg_basebackup from standby (no impact on primary)
   - Schedule and retention policy

---

## Next Steps

1. [ ] Review and approve this design
2. [ ] Decide on open questions
3. [ ] Schedule implementation window
4. [ ] Create detailed runbook scripts
5. [ ] Execute Phase 1-6
6. [ ] Document operational procedures

---

## References

- [pg_auto_failover Documentation](https://pg-auto-failover.readthedocs.io/)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [repmgr Documentation](https://repmgr.org/docs/current/)
- [PostgreSQL Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html)

